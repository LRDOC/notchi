import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SessionStore")

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [String: SessionData] = [:]
    private(set) var selectedSessionId: String?
    private var dismissedSessionIds: Set<String> = []
    private var nextSessionNumberByProject: [String: Int] = [:]

    private init() {}

    var sortedSessions: [SessionData] {
        sessions.values.sorted { lhs, rhs in
            if lhs.isProcessing != rhs.isProcessing {
                return lhs.isProcessing
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var activeSessionCount: Int {
        sessions.count
    }

    var selectedSession: SessionData? {
        guard let id = selectedSessionId else { return nil }
        return sessions[id]
    }

    var effectiveSession: SessionData? {
        if let selected = selectedSession {
            return selected
        }
        if sessions.count == 1 {
            return sessions.values.first
        }
        return sortedSessions.first
    }

    func selectSession(_ sessionId: String?) {
        if let id = sessionId {
            guard sessions[id] != nil else { return }
        }
        selectedSessionId = sessionId
        logger.info("Selected session: \(sessionId ?? "nil", privacy: .public)")
    }

    /// Normalizes an event name to its canonical form.
    static func normalizedEvent(_ event: String) -> String {
        let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = eventAliases[trimmed] {
            return mapped
        }
        if let mapped = eventAliases[trimmed.lowercased()] {
            return mapped
        }
        return trimmed
    }

    /// Normalizes event names from other tools into canonical Notchi event names.
    private static let eventAliases: [String: String] = [
        // Gemini CLI
        "BeforeTool":       "PreToolUse",
        "beforetool":       "PreToolUse",
        "before_tool":      "PreToolUse",
        "AfterTool":        "PostToolUse",
        "aftertool":        "PostToolUse",
        "after_tool":       "PostToolUse",
        "BeforeAgent":      "UserPromptSubmit",
        "beforeagent":      "UserPromptSubmit",
        "before_agent":     "UserPromptSubmit",
        "AfterAgent":       "Stop",
        "afteragent":       "Stop",
        "after_agent":      "Stop",
        "BeforeModel":      "UserPromptSubmit",
        "beforemodel":      "UserPromptSubmit",
        "before_model":     "UserPromptSubmit",
        "PreCompress":      "PreCompact",
        "precompress":      "PreCompact",
        "pre_compress":     "PreCompact",
        // Codex CLI
        "SessionStart":     "SessionStart",
        "session_start":    "SessionStart",
        "SessionEnd":       "SessionEnd",
        "session_end":      "SessionEnd",
        "pre_tool_use":     "PreToolUse",
        "post_tool_use":    "PostToolUse",
        "post_tool_use_failure": "PostToolUse",
        "Stop":             "Stop",
        "stop":             "Stop",
    ]

    func process(_ event: HookEvent) -> SessionData? {
        let source = AIToolSource(rawString: event.resolvedSource)

        guard AppSettings.isToolEnabled(source) else {
            logger.debug("Ignoring event from disabled source: \(source.rawValue, privacy: .public)")
            return nil
        }

        let normalizedEvent = Self.normalizedEvent(event.event)

        if dismissedSessionIds.contains(event.sessionId) {
            guard Self.shouldReactivateDismissedSession(eventName: normalizedEvent) else {
                logger.debug("Ignoring event for dismissed session \(event.sessionId, privacy: .public): \(normalizedEvent, privacy: .public)")
                return nil
            }
            dismissedSessionIds.remove(event.sessionId)
        }

        let isInteractive = event.interactive ?? true
        let session = getOrCreateSession(
            sessionId: event.sessionId,
            cwd: event.cwd,
            source: source,
            isInteractive: isInteractive
        )
        let isProcessing = event.status != "waiting_for_input"
        session.updateProcessingState(isProcessing: isProcessing)

        if let mode = event.permissionMode {
            session.updatePermissionMode(mode)
        }
        if let transcriptPath = Self.cleanedPath(event.transcriptPath) {
            session.updateTranscriptPath(transcriptPath)
        }

        switch normalizedEvent {
        case "UserPromptSubmit":
            let prompt = Self.cleanedPrompt(event.userPrompt)
            if let prompt {
                session.recordUserPrompt(prompt)
            }
            session.clearPendingQuestions()
            if Self.isLocalSlashCommand(prompt) {
                session.updateTask(.idle)
            } else {
                session.updateTask(.working)
            }

        case "PreCompact":
            session.recordLifecycleEvent(type: "PreCompact", description: "Compacting context")
            session.updateTask(.compacting)

        case "SessionStart":
            if let prompt = Self.cleanedPrompt(event.userPrompt) {
                session.recordUserPrompt(prompt)
            }
            session.recordLifecycleEvent(type: "SessionStart", description: "Session started")
            if isProcessing {
                session.updateTask(.working)
            }

        case "PreToolUse":
            let toolInput = event.toolInput?.mapValues { $0.value }
            session.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            if event.tool == "AskUserQuestion" {
                session.updateTask(.waiting)
                session.setPendingQuestions(Self.parseQuestions(from: event.toolInput))
            } else {
                session.clearPendingQuestions()
                session.updateTask(.working)
            }

        case "PermissionRequest":
            let question = Self.buildPermissionQuestion(tool: event.tool, toolInput: event.toolInput)
            session.recordLifecycleEvent(type: "PermissionRequest", description: question.question)
            session.updateTask(.waiting)
            session.setPendingQuestions([question])

        case "PostToolUse":
            let success = event.status != "error"
            session.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            session.clearPendingQuestions()
            session.updateTask(.working)

        case "Stop":
            let shouldRecordReady = !(
                session.task == .idle &&
                session.recentEvents.last?.type == "Stop"
            )
            if shouldRecordReady {
                session.recordLifecycleEvent(type: "Stop", description: "Waiting for input", status: .success)
            }
            session.clearPendingQuestions()
            session.updateTask(.idle)

        case "SubagentStop":
            guard source == .claude else { break }
            session.recordLifecycleEvent(type: "SubagentStop", description: "Subagent finished", status: .success)
            session.clearPendingQuestions()
            session.updateTask(.idle)

        case "SessionEnd":
            session.recordLifecycleEvent(type: "SessionEnd", description: "Session ended", status: .success)
            session.endSession()
            removeSession(event.sessionId)

        default:
            if !isProcessing && session.task != .idle {
                session.updateTask(.idle)
            }
        }

        return session
    }

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.recordAssistantMessages(messages)
    }

    func recordParsedToolEvents(_ events: [ParsedToolEvent], for sessionId: String) {
        guard let session = sessions[sessionId], !events.isEmpty else { return }

        let sortedEvents = events.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                if lhs.phase == rhs.phase {
                    return lhs.id < rhs.id
                }
                return lhs.phase == .pre
            }
            return lhs.timestamp < rhs.timestamp
        }

        for event in sortedEvents {
            if let toolUseId = event.toolUseId {
                let existingEvents = session.recentEvents.filter { $0.toolUseId == toolUseId }

                if event.phase == .pre, !existingEvents.isEmpty {
                    continue
                }

                if event.phase == .post {
                    if existingEvents.contains(where: { $0.status != .running }) {
                        continue
                    }
                }
            }

            if shouldSkipTranscriptToolEvent(event, for: session) {
                continue
            }

            switch event.phase {
            case .pre:
                session.recordPreToolUse(
                    tool: event.tool,
                    toolInput: nil,
                    toolUseId: event.toolUseId,
                    description: event.description,
                    timestamp: event.timestamp
                )
                session.updateTask(.working)
            case .post:
                session.recordPostToolUse(
                    tool: event.tool,
                    toolUseId: event.toolUseId,
                    success: event.success ?? true,
                    timestamp: event.timestamp
                )
                session.updateTask(.working)
            }
        }
    }

    private func shouldSkipTranscriptToolEvent(_ event: ParsedToolEvent, for session: SessionData) -> Bool {
        let canonicalEventTool = Self.canonicalToolName(event.tool)
        let window: TimeInterval = 2.0

        switch event.phase {
        case .pre:
            return session.recentEvents.contains { existing in
                guard Self.canonicalToolName(existing.tool) == canonicalEventTool else { return false }
                let delta = abs(existing.timestamp.timeIntervalSince(event.timestamp))
                return delta <= window
            }

        case .post:
            return session.recentEvents.contains { existing in
                guard Self.canonicalToolName(existing.tool) == canonicalEventTool else { return false }
                guard existing.status != .running else { return false }
                let delta = abs(existing.timestamp.timeIntervalSince(event.timestamp))
                return delta <= window
            }
        }
    }

    private func getOrCreateSession(
        sessionId: String,
        cwd: String,
        source: AIToolSource = .claude,
        isInteractive: Bool = true
    ) -> SessionData {
        if let existing = sessions[sessionId] {
            if existing.source != source, existing.source == .claude, source != .claude {
                existing.updateSource(source)
                logger.info("Updated session source to \(source.rawValue, privacy: .public) for \(sessionId, privacy: .public)")
            }
            return existing
        }

        let projectName = (cwd as NSString).lastPathComponent
        let sessionNumber = nextSessionNumberByProject[projectName, default: 0] + 1
        nextSessionNumberByProject[projectName] = sessionNumber
        let existingXPositions = sessions.values.map(\.spriteXPosition)
        let session = SessionData(
            sessionId: sessionId,
            cwd: cwd,
            sessionNumber: sessionNumber,
            source: source,
            isInteractive: isInteractive,
            existingXPositions: existingXPositions
        )
        sessions[sessionId] = session
        logger.info("Created session #\(sessionNumber): \(sessionId, privacy: .public) at \(cwd, privacy: .public) source: \(source.rawValue, privacy: .public)")

        if activeSessionCount == 1 {
            selectedSessionId = sessionId
        } else {
            selectedSessionId = nil
        }

        return session
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
        logger.info("Removed session: \(sessionId, privacy: .public)")

        if selectedSessionId == sessionId {
            selectedSessionId = nil
        }

        if activeSessionCount == 1 {
            selectedSessionId = sessions.keys.first
        }
    }

    func dismissSession(_ sessionId: String) {
        dismissedSessionIds.insert(sessionId)
        sessions[sessionId]?.endSession()
        removeSession(sessionId)
    }

    private static func parseQuestions(from toolInput: [String: AnyCodable]?) -> [PendingQuestion] {
        guard let input = toolInput?.mapValues({ $0.value }),
              let questions = input["questions"] as? [[String: Any]] else { return [] }

        return questions.compactMap { q in
            guard let questionText = q["question"] as? String else { return nil }
            let header = q["header"] as? String
            let rawOptions = q["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { opt -> (label: String, description: String?)? in
                guard let label = opt["label"] as? String else { return nil }
                return (label: label, description: opt["description"] as? String)
            }
            return PendingQuestion(question: questionText, header: header, options: options)
        }
    }

    private static let localSlashCommands: Set<String> = [
        "/clear", "/help", "/cost", "/status",
        "/vim", "/fast", "/model", "/login", "/logout",
    ]

    private static func cleanedPrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isLocalSlashCommand(_ prompt: String?) -> Bool {
        guard let prompt, prompt.hasPrefix("/") else { return false }
        let command = String(prompt.prefix(while: { !$0.isWhitespace }))
        return localSlashCommands.contains(command)
    }

    private static func buildPermissionQuestion(tool: String?, toolInput: [String: AnyCodable]?) -> PendingQuestion {
        let toolName = tool ?? "Tool"
        let input = toolInput?.mapValues { $0.value }
        let description = SessionEvent.deriveDescription(tool: tool, toolInput: input)
        return PendingQuestion(
            question: description ?? "\(toolName) wants to proceed",
            header: "Permission Request",
            // Claude Code permission prompts always present these three choices
            options: [
                (label: "Yes", description: nil),
                (label: "Yes, and don't ask again", description: nil),
                (label: "No", description: nil),
            ]
        )
    }

    private static func shouldReactivateDismissedSession(eventName: String) -> Bool {
        switch eventName {
        case "UserPromptSubmit", "PreToolUse":
            return true
        default:
            return false
        }
    }

    private static func canonicalToolName(_ rawTool: String?) -> String {
        guard let rawTool else { return "" }
        let normalized = rawTool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "readfolder", "read_folder", "list_directory":
            return "list_directory"
        case "run_shell_command", "bash", "exec_command":
            return "bash"
        case "read", "read_file":
            return "read_file"
        case "write", "write_file":
            return "write_file"
        case "edit", "edit_file":
            return "edit_file"
        case "grep", "search_file_content":
            return "search_file_content"
        default:
            return normalized
        }
    }
}
