import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    struct CodexBackfillSeed: Sendable, Equatable {
        let sessionId: String
        let cwd: String
        let transcriptPath: String
        let userPrompt: String?
        let finishedAt: Date
    }

    let sessionStore = SessionStore.shared

    private var emotionDecayTimer: Task<Void, Never>?
    private var nonClaudeLivePollTask: Task<Void, Never>?
    private var pendingSyncTasks: [String: Task<Void, Never>] = [:]
    private var pendingPositionMarks: [String: Task<Void, Never>] = [:]
    private var transientActivityTasks: [String: Task<Void, Never>] = [:]
    private var liveSyncInFlight: Set<String> = []
    private var fileWatchers: [String: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]
    var handleClaudeUsageResumeTrigger: (ClaudeUsageResumeTrigger) -> Void = { trigger in
        ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
    }

    private static let syncDebounce: Duration = .milliseconds(100)
    private static let waitingClearGuard: TimeInterval = 2.0
    private static let nonClaudeLivePollInterval: Duration = .milliseconds(850)
    nonisolated private static let codexBackfillInitialLookback: TimeInterval = 6 * 60 * 60
    nonisolated private static let codexBackfillReplayOverlap: TimeInterval = 15
    nonisolated private static let codexBackfillMaxSessions = 8
    nonisolated private static let codexBackfillPrefixBytes = 64 * 1024
    nonisolated private static let codexBackfillTailBytes = 256 * 1024

    var currentState: NotchiState {
        sessionStore.effectiveSession?.state ?? .idle
    }

    private init() {
        startEmotionDecayTimer()
        startNonClaudeLivePoller()
        recoverRecentCodexSessions()
    }

    func handleEvent(_ event: HookEvent) {
        let source = AIToolSource(rawString: event.resolvedSource)
        guard AppSettings.isToolEnabled(source) else { return }
        if source == .codex {
            AppSettings.codexLastIngestAt = Date()
        }
        guard let session = sessionStore.process(event) else { return }

        let isDone = event.status == "waiting_for_input"
        let isClaudeSource = source == .claude
        let normalizedEvent = SessionStore.normalizedEvent(event.event)

        switch normalizedEvent {
        case "UserPromptSubmit":
            if isClaudeSource {
                pendingPositionMarks[event.sessionId] = Task {
                    await ConversationParser.shared.markCurrentPosition(
                        sessionId: event.sessionId,
                        cwd: event.cwd,
                        source: source,
                        transcriptPath: session.transcriptPath
                    )
                }
            } else {
                pendingPositionMarks.removeValue(forKey: event.sessionId)?.cancel()
            }

            if isClaudeSource, session.isInteractive {
                startFileWatcher(sessionId: event.sessionId, cwd: event.cwd)
            }

            if session.isInteractive, let prompt = event.userPrompt {
                Task {
                    let result = await EmotionAnalyzer.shared.analyze(prompt)
                    session.emotionState.recordEmotion(result.emotion, intensity: result.intensity, prompt: prompt)
                }
            }

            if session.isInteractive, !SessionStore.isLocalSlashCommand(event.userPrompt) {
                handleClaudeUsageResumeTrigger(.userPromptSubmit)
            }

        case "PreToolUse":
            if isDone {
                SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)
            }

        case "PermissionRequest":
            SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)

        case "PostToolUse":
            scheduleFileSync(
                sessionId: event.sessionId,
                cwd: event.cwd,
                source: source,
                transcriptPath: session.transcriptPath
            )

        case "SessionStart":
            handleClaudeUsageResumeTrigger(.sessionStart)

        case "Stop":
            SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)
            stopFileWatcher(sessionId: event.sessionId)
            scheduleFileSync(
                sessionId: event.sessionId,
                cwd: event.cwd,
                source: source,
                transcriptPath: session.transcriptPath
            )

        case "SessionEnd":
            if isClaudeSource {
                stopFileWatcher(sessionId: event.sessionId)
            }
            pendingSyncTasks.removeValue(forKey: event.sessionId)?.cancel()
            pendingPositionMarks.removeValue(forKey: event.sessionId)?.cancel()
            SoundService.shared.clearCooldown(for: event.sessionId)
            Task { await ConversationParser.shared.resetState(for: event.sessionId) }
            if sessionStore.activeSessionCount == 0 {
                logger.info("Global state: idle")
            }
            return

        default:
            if isDone && session.task != .idle {
                SoundService.shared.playNotificationSound(sessionId: event.sessionId, isInteractive: session.isInteractive)
            }
        }

        session.resetSleepTimer()
    }

    private func scheduleFileSync(
        sessionId: String,
        cwd: String,
        source: AIToolSource,
        transcriptPath: String?
    ) {
        pendingSyncTasks[sessionId]?.cancel()
        pendingSyncTasks[sessionId] = Task {
            // Wait for position marking to complete first
            await pendingPositionMarks[sessionId]?.value

            try? await Task.sleep(for: Self.syncDebounce)
            guard !Task.isCancelled else { return }

            await syncIncremental(
                sessionId: sessionId,
                cwd: cwd,
                source: source,
                transcriptPath: transcriptPath
            )
            pendingSyncTasks.removeValue(forKey: sessionId)
        }
    }

    private func syncIncremental(
        sessionId: String,
        cwd: String,
        source: AIToolSource,
        transcriptPath: String?
    ) async {
        let result = await ConversationParser.shared.parseIncremental(
            sessionId: sessionId,
            cwd: cwd,
            source: source,
            transcriptPath: transcriptPath
        )

        if let prompt = Self.cleanedPrompt(result.latestUserPrompt),
           let session = sessionStore.sessions[sessionId],
           session.lastUserPrompt != prompt {
            session.recordUserPrompt(prompt)
        }

        if let session = sessionStore.sessions[sessionId],
           let earliestActivity = Self.earliestActivityTimestamp(from: result) {
            session.backdatePromptSubmitTimeIfNeeded(earliestActivity.addingTimeInterval(-0.1))
        }

        if !result.toolEvents.isEmpty {
            sessionStore.recordParsedToolEvents(result.toolEvents, for: sessionId)
        }

        if !result.messages.isEmpty {
            sessionStore.recordAssistantMessages(result.messages, for: sessionId)
        }

        if !result.messages.isEmpty || !result.toolEvents.isEmpty {
            pulseTransientActivity(sessionId: sessionId, source: source)
        }

        guard let session = sessionStore.sessions[sessionId] else {
            return
        }

        if result.interrupted && session.task == .working {
            session.updateTask(.idle)
            session.updateProcessingState(isProcessing: false)
        } else if session.task == .waiting,
                  Date().timeIntervalSince(session.lastActivity) > Self.waitingClearGuard {
            session.clearPendingQuestions()
            session.updateTask(.working)
        }
    }

    private func startNonClaudeLivePoller() {
        nonClaudeLivePollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.nonClaudeLivePollInterval)
                guard !Task.isCancelled else { return }
                pollNonClaudeSessions()
            }
        }
    }

    private func recoverRecentCodexSessions() {
        guard AppSettings.isToolEnabled(.codex) else { return }

        let now = Date()
        let since = AppSettings.codexLastIngestAt?.addingTimeInterval(-Self.codexBackfillReplayOverlap)
            ?? now.addingTimeInterval(-Self.codexBackfillInitialLookback)

        Task.detached(priority: .utility) { [now, since] in
            let root = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/sessions", isDirectory: true)
            let seeds = Self.discoverCodexBackfillSeeds(
                rootURL: root,
                since: since,
                maxCount: Self.codexBackfillMaxSessions
            )

            await MainActor.run {
                self.applyCodexBackfillSeeds(seeds)
                AppSettings.codexLastIngestAt = now
            }
        }
    }

    private func applyCodexBackfillSeeds(_ seeds: [CodexBackfillSeed]) {
        guard !seeds.isEmpty else { return }

        var recoveredCount = 0
        for seed in seeds where sessionStore.sessions[seed.sessionId] == nil {
            if let prompt = Self.cleanedPrompt(seed.userPrompt) {
                _ = sessionStore.process(
                    HookEvent(
                        sessionId: seed.sessionId,
                        cwd: seed.cwd,
                        event: "UserPromptSubmit",
                        status: "processing",
                        userPrompt: prompt,
                        transcriptPath: seed.transcriptPath,
                        permissionMode: "default",
                        source: "codex",
                        interactive: true
                    )
                )
            }

            let stopEvent = HookEvent(
                sessionId: seed.sessionId,
                cwd: seed.cwd,
                event: "Stop",
                status: "waiting_for_input",
                transcriptPath: seed.transcriptPath,
                permissionMode: "default",
                source: "codex",
                interactive: true
            )
            guard let session = sessionStore.process(stopEvent) else { continue }

            scheduleFileSync(
                sessionId: seed.sessionId,
                cwd: seed.cwd,
                source: .codex,
                transcriptPath: seed.transcriptPath
            )
            session.resetSleepTimer()
            recoveredCount += 1
        }

        if recoveredCount > 0 {
            logger.info("Recovered \(recoveredCount) recent Codex session(s) at launch")
        }
    }

    nonisolated static func discoverCodexBackfillSeeds(
        rootURL: URL,
        since: Date,
        maxCount: Int
    ) -> [CodexBackfillSeed] {
        guard maxCount > 0 else { return [] }
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values?.isRegularFile == false { continue }

            let modifiedAt = values?.contentModificationDate ?? .distantPast
            guard modifiedAt >= since else { continue }
            candidates.append((url: fileURL, modifiedAt: modifiedAt))
        }

        candidates.sort { lhs, rhs in
            lhs.modifiedAt > rhs.modifiedAt
        }

        var seenSessionIds: Set<String> = []
        var seeds: [CodexBackfillSeed] = []

        for candidate in candidates {
            guard let seed = codexBackfillSeed(
                transcriptURL: candidate.url,
                modifiedAt: candidate.modifiedAt
            ) else {
                continue
            }

            guard seenSessionIds.insert(seed.sessionId).inserted else { continue }
            seeds.append(seed)
            if seeds.count >= maxCount { break }
        }

        return seeds.sorted { lhs, rhs in
            lhs.finishedAt < rhs.finishedAt
        }
    }

    private struct CodexBackfillMetadata {
        let cwd: String?
        let userPrompt: String?
    }

    nonisolated private static func codexBackfillSeed(
        transcriptURL: URL,
        modifiedAt: Date
    ) -> CodexBackfillSeed? {
        guard let sessionId = codexSessionID(fromFilename: transcriptURL.lastPathComponent) else {
            return nil
        }

        let metadata = codexBackfillMetadata(from: transcriptURL)
        let cwd = cleanedPath(metadata.cwd) ?? NSHomeDirectory()
        guard !cwd.isEmpty else { return nil }

        return CodexBackfillSeed(
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: transcriptURL.path,
            userPrompt: cleanedPrompt(metadata.userPrompt),
            finishedAt: modifiedAt
        )
    }

    nonisolated private static func codexSessionID(fromFilename filename: String) -> String? {
        let basename = filename.hasSuffix(".jsonl")
            ? String(filename.dropLast(6))
            : filename
        guard !basename.isEmpty else { return nil }

        if let range = basename.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ) {
            return String(basename[range]).lowercased()
        }

        return basename
    }

    nonisolated private static func codexBackfillMetadata(from transcriptURL: URL) -> CodexBackfillMetadata {
        var detectedCwd: String?
        var detectedPrompt: String?

        if let prefix = readFilePrefix(at: transcriptURL, maxBytes: Self.codexBackfillPrefixBytes) {
            for line in prefix.split(whereSeparator: \.isNewline) {
                guard let record = decodeJSONLine(line) else { continue }
                if let cwd = codexCwd(in: record) {
                    detectedCwd = cwd
                    break
                }
            }
        }

        if let tail = readFileTail(at: transcriptURL, maxBytes: Self.codexBackfillTailBytes) {
            for line in tail.split(whereSeparator: \.isNewline).reversed() {
                guard let record = decodeJSONLine(line) else { continue }

                if detectedPrompt == nil, let prompt = codexPrompt(in: record) {
                    detectedPrompt = prompt
                }
                if detectedCwd == nil, let cwd = codexCwd(in: record) {
                    detectedCwd = cwd
                }
                if detectedPrompt != nil, detectedCwd != nil {
                    break
                }
            }
        }

        return CodexBackfillMetadata(cwd: detectedCwd, userPrompt: detectedPrompt)
    }

    nonisolated private static func readFilePrefix(at url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes),
              !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func readFileTail(at url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let maxTail = UInt64(maxBytes)
        let startOffset = fileSize > maxTail ? (fileSize - maxTail) : 0
        try? handle.seek(toOffset: startOffset)

        guard let data = try? handle.readToEnd(),
              !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func decodeJSONLine<S: StringProtocol>(_ line: S) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated private static func codexCwd(in record: [String: Any]) -> String? {
        for key in ["cwd", "workdir", "working_directory", "working-directory", "project_dir"] {
            if let direct = cleanedPath(record[key] as? String) {
                return direct
            }
        }

        guard let payload = record["payload"] as? [String: Any] else { return nil }
        for key in ["cwd", "workdir", "working_directory", "working-directory", "project_dir"] {
            if let nested = cleanedPath(payload[key] as? String) {
                return nested
            }
        }

        return nil
    }

    nonisolated private static func codexPrompt(in record: [String: Any]) -> String? {
        let type = (record["type"] as? String)?.lowercased() ?? ""

        if type == "response_item",
           let payload = record["payload"] as? [String: Any],
           (payload["type"] as? String) == "message",
           (payload["role"] as? String)?.lowercased() == "user" {
            return codexText(from: payload["content"])
        }

        if type == "event_msg", let payload = record["payload"] as? [String: Any] {
            if (payload["type"] as? String) == "user_message" {
                if let prompt = codexText(from: payload["message"]) {
                    return prompt
                }
            }
            if let prompt = codexPromptFromInputMessages(payload["input-messages"] ?? payload["input_messages"] ?? payload["inputMessages"]) {
                return prompt
            }
        }

        if type == "turn_context",
           let payload = record["payload"] as? [String: Any],
           let prompt = codexPromptFromInputMessages(payload["input-messages"] ?? payload["input_messages"] ?? payload["inputMessages"]) {
            return prompt
        }

        return nil
    }

    nonisolated private static func codexPromptFromInputMessages(_ value: Any?) -> String? {
        guard let messages = value as? [Any] else { return nil }

        for message in messages.reversed() {
            if let text = codexText(from: message) {
                return text
            }

            guard let dict = message as? [String: Any] else { continue }
            if let role = dict["role"] as? String, !role.lowercased().contains("user") {
                continue
            }
            if let prompt = codexText(from: dict["content"] ?? dict["text"] ?? dict["message"] ?? dict["input"]) {
                return prompt
            }
        }

        return nil
    }

    nonisolated private static func codexText(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return cleanedPrompt(text)

        case let dictionary as [String: Any]:
            for key in ["text", "content", "value", "message", "prompt", "input"] {
                if let text = codexText(from: dictionary[key]) {
                    return text
                }
            }
            return nil

        case let array as [Any]:
            let parts = array.compactMap { codexText(from: $0) }
            guard !parts.isEmpty else { return nil }
            return cleanedPrompt(parts.joined(separator: "\n"))

        default:
            return nil
        }
    }

    private func pollNonClaudeSessions() {
        let sessionsToPoll = sessionStore.sessions.values.filter {
            $0.source != .claude && $0.isInteractive
        }

        for session in sessionsToPoll {
            let sessionId = session.id
            guard !liveSyncInFlight.contains(sessionId) else { continue }
            liveSyncInFlight.insert(sessionId)

            let cwd = session.cwd
            let source = session.source
            let transcriptPath = session.transcriptPath

            Task { @MainActor in
                defer { liveSyncInFlight.remove(sessionId) }
                await syncIncremental(
                    sessionId: sessionId,
                    cwd: cwd,
                    source: source,
                    transcriptPath: transcriptPath
                )
            }
        }
    }

    nonisolated private static func cleanedPrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func cleanedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func earliestActivityTimestamp(from result: ParseResult) -> Date? {
        let messageTimes = result.messages.map(\.timestamp)
        let toolTimes = result.toolEvents.map(\.timestamp)
        return (messageTimes + toolTimes).min()
    }

    private func pulseTransientActivity(sessionId: String, source: AIToolSource) {
        guard source != .claude else { return }
        guard let session = sessionStore.sessions[sessionId] else { return }
        guard !session.isProcessing else { return }

        transientActivityTasks[sessionId]?.cancel()
        session.updateTask(.working)

        transientActivityTasks[sessionId] = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            guard let session = sessionStore.sessions[sessionId] else {
                transientActivityTasks.removeValue(forKey: sessionId)
                return
            }
            if !session.isProcessing && session.task == .working {
                session.updateTask(.idle)
            }
            transientActivityTasks.removeValue(forKey: sessionId)
        }
    }

    func reconcileFileSyncResult(_ result: ParseResult, for sessionId: String, hasActiveWatcher: Bool) {
        guard let session = sessionStore.sessions[sessionId] else { return }

        if !result.messages.isEmpty,
           session.isInteractive,
           hasActiveWatcher,
           session.task == .idle || session.task == .sleeping {
            session.updateTask(.working)
            session.updateProcessingState(isProcessing: true)
        }

        if result.interrupted && session.task == .working {
            session.updateTask(.idle)
            session.updateProcessingState(isProcessing: false)
        } else if session.task == .waiting,
                  Date().timeIntervalSince(session.lastActivity) > Self.waitingClearGuard {
            session.clearPendingQuestions()
            session.updateTask(.working)
        }
    }

    private func startFileWatcher(sessionId: String, cwd: String) {
        stopFileWatcher(sessionId: sessionId)

        let sessionFile = ConversationParser.sessionFilePath(sessionId: sessionId, cwd: cwd)

        let fd = open(sessionFile, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open file for watching: \(sessionFile)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleFileSync(
                sessionId: sessionId,
                cwd: cwd,
                source: .claude,
                transcriptPath: nil
            )
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchers[sessionId] = (source: source, fd: fd)
        logger.debug("Started file watcher for session \(sessionId)")
    }

    private func stopFileWatcher(sessionId: String) {
        guard let watcher = fileWatchers.removeValue(forKey: sessionId) else { return }
        watcher.source.cancel()
        logger.debug("Stopped file watcher for session \(sessionId)")
    }

    private func startEmotionDecayTimer() {
        emotionDecayTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: EmotionState.decayInterval)
                guard !Task.isCancelled else { return }
                for session in sessionStore.sessions.values {
                    session.emotionState.decayAll()
                }
            }
        }
    }

    func resetTestingHooks() {
        handleClaudeUsageResumeTrigger = { trigger in
            ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
        }
    }

}
