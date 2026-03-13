import Foundation

struct HookEvent: Decodable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let userPrompt: String?
    let transcriptPath: String?
    let permissionMode: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionIdCamel = "sessionId"
        case session
        case id
        case threadId = "thread-id"
        case threadIdSnake = "thread_id"
        case conversationId = "conversation_id"
        case invocationId = "invocation_id"
        case cwd
        case workdir
        case workingDirectory = "working_directory"
        case workingDirectoryKebab = "working-directory"
        case projectDir = "project_dir"
        case event
        case eventType = "type"
        case status, pid, tty, tool
        case toolName = "tool_name"
        case eventName = "event_name"
        case hookEventName = "hook_event_name"
        case hookEvent = "hook_event"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case callId = "call_id"
        case callID = "callId"
        case userPrompt = "user_prompt"
        case userPromptCamel = "userPrompt"
        case userPromptKebab = "user-prompt"
        case prompt
        case transcriptPath = "transcript_path"
        case sessionPath = "session_path"
        case permissionMode = "permission_mode"
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nestedHookEvent = (try? container.decodeIfPresent([String: AnyCodable].self, forKey: .hookEvent))?
            .mapValues(\.value)

        sessionId =
            Self.decodeOptionalString(
                from: container,
                keys: [.sessionId, .sessionIdCamel, .threadId, .threadIdSnake, .conversationId, .invocationId, .session, .id]
            )
            ?? ""
        cwd =
            Self.decodeOptionalString(
                from: container,
                keys: [.cwd, .workdir, .workingDirectory, .workingDirectoryKebab, .projectDir]
            )
            ?? ""
        event =
            Self.decodeOptionalString(from: container, keys: [.event, .eventName, .hookEventName, .eventType])
            ?? Self.stringValue(from: nestedHookEvent?["event_type"])
            ?? Self.stringValue(from: nestedHookEvent?["hook_event_name"])
            ?? ""
        status = Self.decodeString(from: container, key: .status, default: "unknown")
        pid = Self.decodeOptionalInt(from: container, key: .pid)
        tty = Self.decodeOptionalString(from: container, key: .tty)
        tool = Self.decodeOptionalString(from: container, keys: [.tool, .toolName])
        toolInput = (try? container.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)) ?? nil
        toolUseId = Self.decodeOptionalString(from: container, keys: [.toolUseId, .callId, .callID])
        userPrompt =
            Self.decodeOptionalString(from: container, keys: [.userPrompt, .userPromptCamel, .userPromptKebab, .prompt])
            ?? Self.stringValue(from: nestedHookEvent?["user_prompt"])
            ?? Self.stringValue(from: nestedHookEvent?["userPrompt"])
            ?? Self.stringValue(from: nestedHookEvent?["user-prompt"])
            ?? Self.stringValue(from: nestedHookEvent?["prompt"])
        transcriptPath = Self.decodeOptionalString(from: container, keys: [.transcriptPath, .sessionPath])
        permissionMode = Self.decodeOptionalString(from: container, key: .permissionMode)
        source = Self.decodeOptionalString(from: container, key: .source)
    }

    var resolvedSource: String {
        if let normalized = Self.normalizeSource(source) {
            return normalized
        }

        let normalizedSessionId = sessionId.lowercased()
        if normalizedSessionId.hasPrefix("codex-") { return "codex" }
        if normalizedSessionId.hasPrefix("gemini-") { return "gemini" }
        if let inferred = Self.inferSource(fromEvent: event) { return inferred }

        return "claude"
    }

    private static func decodeString(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        default defaultValue: String
    ) -> String {
        decodeOptionalString(from: container, key: key) ?? defaultValue
    }

    private static func decodeOptionalString(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeOptionalString(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = decodeOptionalString(from: container, key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringValue(from value: Any?) -> String? {
        guard let value else { return nil }

        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return String(bool)
        default:
            return nil
        }
    }

    private static func decodeOptionalInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key),
           let parsed = Int(value) {
            return parsed
        }
        return nil
    }

    private static func normalizeSource(_ source: String?) -> String? {
        guard let raw = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty else {
            return nil
        }

        switch raw {
        case "claude", "claudecode", "claude-code", "claude code":
            return "claude"
        case "gemini", "geminicli", "gemini-cli", "gemini cli":
            return "gemini"
        case "codex", "codexcli", "codex-cli", "codex cli":
            return "codex"
        default:
            break
        }

        if raw.contains("codex") { return "codex" }
        if raw.contains("gemini") { return "gemini" }
        if raw.contains("claude") { return "claude" }

        return nil
    }

    private static func inferSource(fromEvent event: String) -> String? {
        let raw = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }

        switch raw {
        case "pre_tool_use", "post_tool_use", "post_tool_use_failure", "after_tool_use", "agent-turn-complete", "agent_turn_complete":
            return "codex"
        case "beforetool", "aftertool", "beforeagent", "afteragent", "precompress", "beforemodel", "aftermodel":
            return "gemini"
        default:
            return nil
        }
    }
}

struct AnyCodable: Decodable, @unchecked Sendable {
    nonisolated(unsafe) let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode value"
            )
        }
    }
}
