import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    let sessionStore = SessionStore.shared

    private var emotionDecayTimer: Task<Void, Never>?
    private var pendingSyncTasks: [String: Task<Void, Never>] = [:]
    private var pendingPositionMarks: [String: Task<Void, Never>] = [:]
    private var transientActivityTasks: [String: Task<Void, Never>] = [:]
    private var fileWatchers: [String: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]

    private static let syncDebounce: Duration = .milliseconds(100)
    private static let waitingClearGuard: TimeInterval = 2.0

    var currentState: NotchiState {
        sessionStore.effectiveSession?.state ?? .idle
    }

    private init() {
        startEmotionDecayTimer()
    }

    func handleEvent(_ event: HookEvent) {
        let source = AIToolSource(rawString: event.resolvedSource)
        guard AppSettings.isToolEnabled(source) else { return }
        guard let session = sessionStore.process(event) else { return }

        let isDone = event.status == "waiting_for_input"
        let isClaudeSource = source == .claude
        let normalizedEvent = SessionStore.normalizedEvent(event.event)

        switch normalizedEvent {
        case "UserPromptSubmit":
            if isClaudeSource || source == .gemini {
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

            if isClaudeSource {
                startFileWatcher(sessionId: event.sessionId, cwd: event.cwd)
            }

            if let prompt = event.userPrompt {
                Task {
                    let result = await EmotionAnalyzer.shared.analyze(prompt)
                    session.emotionState.recordEmotion(result.emotion, intensity: result.intensity, prompt: prompt)
                }
            }

        case "PreToolUse":
            if isDone {
                SoundService.shared.playNotificationSound()
            }

        case "PermissionRequest":
            SoundService.shared.playNotificationSound()

        case "PostToolUse":
            scheduleFileSync(
                sessionId: event.sessionId,
                cwd: event.cwd,
                source: source,
                transcriptPath: session.transcriptPath
            )

        case "Stop":
            SoundService.shared.playNotificationSound()
            if isClaudeSource {
                stopFileWatcher(sessionId: event.sessionId)
            }
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
            Task { await ConversationParser.shared.resetState(for: event.sessionId) }
            if sessionStore.activeSessionCount == 0 {
                logger.info("Global state: idle")
            }
            return

        default:
            if isDone && session.task != .idle {
                SoundService.shared.playNotificationSound()
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
                pendingSyncTasks.removeValue(forKey: sessionId)
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

            pendingSyncTasks.removeValue(forKey: sessionId)
        }
    }

    private static func cleanedPrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
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

}
