//
//  ConversationParser.swift
//  notchi
//
//  Parses assistant responses from CLI transcript files.
//

import Foundation

enum ParsedToolEventPhase: Sendable {
    case pre
    case post
}

struct ParsedToolEvent: Sendable {
    let id: String
    let timestamp: Date
    let phase: ParsedToolEventPhase
    let tool: String
    let toolUseId: String?
    let description: String?
    let success: Bool?
}

struct ParseResult {
    let messages: [AssistantMessage]
    let toolEvents: [ParsedToolEvent]
    let interrupted: Bool
    let latestUserPrompt: String?
}

actor ConversationParser {
    static let shared = ConversationParser()

    private var lastFileOffset: [String: UInt64] = [:]
    private var seenMessageIds: [String: Set<String>] = [:]
    private var seenToolEventIds: [String: Set<String>] = [:]
    private var pendingCodexCalls: [String: [String: (tool: String, description: String?)]] = [:]
    private var resolvedSessionFiles: [String: String] = [:]

    private static let emptyResult = ParseResult(messages: [], toolEvents: [], interrupted: false, latestUserPrompt: nil)
    private static let codexInitialTailBytes: UInt64 = 200_000

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parse only NEW assistant text messages since last call.
    func parseIncremental(sessionId: String, cwd: String, source: AIToolSource, transcriptPath: String?) -> ParseResult {
        guard let sessionFile = resolveSessionFilePath(
            sessionId: sessionId,
            cwd: cwd,
            source: source,
            transcriptPath: transcriptPath
        ) else {
            return Self.emptyResult
        }

        switch source {
        case .claude:
            return parseClaudeIncremental(sessionId: sessionId, filePath: sessionFile)
        case .codex:
            return parseCodexIncremental(sessionId: sessionId, filePath: sessionFile)
        case .gemini:
            return parseGeminiSnapshot(sessionId: sessionId, filePath: sessionFile)
        }
    }

    /// Reset parsing state for a session.
    func resetState(for sessionId: String) {
        lastFileOffset.removeValue(forKey: sessionId)
        seenMessageIds.removeValue(forKey: sessionId)
        seenToolEventIds.removeValue(forKey: sessionId)
        pendingCodexCalls.removeValue(forKey: sessionId)
        resolvedSessionFiles.removeValue(forKey: sessionId)
    }

    /// Mark current file position as already processed.
    func markCurrentPosition(sessionId: String, cwd: String, source: AIToolSource, transcriptPath: String?) {
        guard let sessionFile = resolveSessionFilePath(
            sessionId: sessionId,
            cwd: cwd,
            source: source,
            transcriptPath: transcriptPath
        ) else {
            lastFileOffset[sessionId] = 0
            seenMessageIds[sessionId] = []
            seenToolEventIds[sessionId] = []
            pendingCodexCalls[sessionId] = [:]
            return
        }

        switch source {
        case .claude, .codex:
            guard let fileHandle = FileHandle(forReadingAtPath: sessionFile) else {
                lastFileOffset[sessionId] = 0
                seenMessageIds[sessionId] = []
                return
            }
            defer { try? fileHandle.close() }
            let fileSize = (try? fileHandle.seekToEnd()) ?? 0
            lastFileOffset[sessionId] = fileSize
            seenMessageIds[sessionId] = []
            seenToolEventIds[sessionId] = []
            pendingCodexCalls[sessionId] = [:]

        case .gemini:
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionFile)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let messageObjects = json["messages"] as? [[String: Any]] else {
                seenMessageIds[sessionId] = []
                seenToolEventIds[sessionId] = []
                return
            }
            var seen: Set<String> = []
            var seenToolEvents: Set<String> = []
            for message in messageObjects {
                if let id = message["id"] as? String {
                    seen.insert(id)
                }
                guard let toolCalls = message["toolCalls"] as? [[String: Any]] else { continue }
                for (index, toolCall) in toolCalls.enumerated() {
                    let callId = (toolCall["id"] as? String)
                        ?? "\(message["id"] as? String ?? "gemini-call")-\(index)"
                    seenToolEvents.insert("gemini-pre-\(callId)")
                    seenToolEvents.insert("gemini-post-\(callId)")
                }
            }
            seenMessageIds[sessionId] = seen
            seenToolEventIds[sessionId] = seenToolEvents
        }
    }

    static func sessionFilePath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return "\(NSHomeDirectory())/.claude/projects/\(projectDir)/\(sessionId).jsonl"
    }

    private func parseClaudeIncremental(sessionId: String, filePath: String) -> ParseResult {
        guard let linesAndState = readNewLines(sessionId: sessionId, filePath: filePath) else {
            return Self.emptyResult
        }

        var messages: [AssistantMessage] = []
        var interrupted = false
        var seen = seenMessageIds[sessionId] ?? []

        for line in linesAndState.lines where !line.isEmpty {
            if !interrupted &&
                line.contains("\"type\":\"user\"") &&
                line.contains("\"text\":\"[Request interrupted by user") {
                interrupted = true
            }

            guard line.contains("\"type\":\"assistant\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "assistant",
                  let uuid = json["uuid"] as? String else {
                continue
            }

            if seen.contains(uuid) { continue }
            if json["isMeta"] as? Bool == true { continue }
            guard let messageDict = json["message"] as? [String: Any] else { continue }

            let timestamp = parseTimestamp(json["timestamp"])

            var textParts: [String] = []
            if let content = messageDict["content"] as? String {
                if !content.hasPrefix("<command-name>") &&
                    !content.hasPrefix("[Request interrupted") {
                    textParts.append(content)
                }
            } else if let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    guard let blockType = block["type"] as? String else { continue }
                    if blockType == "text", let text = block["text"] as? String {
                        if !text.hasPrefix("[Request interrupted") {
                            textParts.append(text)
                        }
                    }
                }
            }

            let fullText = textParts
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullText.isEmpty else { continue }

            seen.insert(uuid)
            messages.append(AssistantMessage(id: uuid, text: fullText, timestamp: timestamp))
        }

        lastFileOffset[sessionId] = linesAndState.fileSize
        seenMessageIds[sessionId] = seen

        return ParseResult(messages: messages, toolEvents: [], interrupted: interrupted, latestUserPrompt: nil)
    }

    private func parseCodexIncremental(sessionId: String, filePath: String) -> ParseResult {
        guard let linesAndState = readNewLines(
            sessionId: sessionId,
            filePath: filePath,
            initialTailBytes: Self.codexInitialTailBytes
        ) else {
            return Self.emptyResult
        }

        var messages: [AssistantMessage] = []
        var toolEvents: [ParsedToolEvent] = []
        var seen = seenMessageIds[sessionId] ?? []
        var seenToolEvents = seenToolEventIds[sessionId] ?? []
        var pendingCalls = pendingCodexCalls[sessionId] ?? [:]
        var latestUserPrompt: (text: String, timestamp: Date)?

        for line in linesAndState.lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let recordType = json["type"] as? String else {
                continue
            }

            let timestamp = parseTimestamp(json["timestamp"])

            guard recordType == "response_item",
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                continue
            }

            if payloadType == "function_call" {
                let callId = (payload["call_id"] as? String)
                    ?? "codex-call-\(timestamp.timeIntervalSince1970)"
                let functionName = payload["name"] as? String
                let arguments = parseJSONObjectString(payload["arguments"] as? String)
                let toolName = codexToolDisplayName(functionName: functionName)
                let description = codexToolDescription(functionName: functionName, arguments: arguments)

                pendingCalls[callId] = (tool: toolName, description: description)

                let eventId = "codex-pre-\(callId)"
                if !seenToolEvents.contains(eventId) {
                    seenToolEvents.insert(eventId)
                    toolEvents.append(
                        ParsedToolEvent(
                            id: eventId,
                            timestamp: timestamp,
                            phase: .pre,
                            tool: toolName,
                            toolUseId: callId,
                            description: description,
                            success: nil
                        )
                    )
                }
                continue
            }

            if payloadType == "function_call_output" {
                guard let callId = payload["call_id"] as? String, !callId.isEmpty else { continue }
                let eventId = "codex-post-\(callId)"
                guard !seenToolEvents.contains(eventId) else { continue }

                let callInfo = pendingCalls[callId]
                let output = payload["output"] as? String
                let success = codexCallSucceeded(payload: payload, output: output)

                seenToolEvents.insert(eventId)
                toolEvents.append(
                    ParsedToolEvent(
                        id: eventId,
                        timestamp: timestamp,
                        phase: .post,
                        tool: callInfo?.tool ?? "Bash",
                        toolUseId: callId,
                        description: callInfo?.description,
                        success: success
                    )
                )
                pendingCalls.removeValue(forKey: callId)
                continue
            }

            if payloadType == "message", let role = payload["role"] as? String {
                if role == "assistant" {
                    let text = extractCodexAssistantText(from: payload)
                    guard !text.isEmpty else { continue }

                    let id = (payload["id"] as? String)
                        ?? "codex-\(timestamp.timeIntervalSince1970)-\(text.hashValue)"
                    if seen.contains(id) { continue }

                    seen.insert(id)
                    messages.append(AssistantMessage(id: id, text: text, timestamp: timestamp))
                    continue
                }

                if role == "user" {
                    let text = extractCodexMessageText(from: payload)
                    guard !text.isEmpty else { continue }
                    if let current = latestUserPrompt {
                        if timestamp >= current.timestamp {
                            latestUserPrompt = (text: text, timestamp: timestamp)
                        }
                    } else {
                        latestUserPrompt = (text: text, timestamp: timestamp)
                    }
                }
            }
        }

        lastFileOffset[sessionId] = linesAndState.fileSize
        seenMessageIds[sessionId] = seen
        seenToolEventIds[sessionId] = seenToolEvents
        pendingCodexCalls[sessionId] = pendingCalls

        return ParseResult(
            messages: messages,
            toolEvents: toolEvents,
            interrupted: false,
            latestUserPrompt: latestUserPrompt?.text
        )
    }

    private func parseGeminiSnapshot(sessionId: String, filePath: String) -> ParseResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageObjects = json["messages"] as? [[String: Any]] else {
            return Self.emptyResult
        }

        var seen = seenMessageIds[sessionId] ?? []
        var seenToolEvents = seenToolEventIds[sessionId] ?? []
        var messages: [AssistantMessage] = []
        var toolEvents: [ParsedToolEvent] = []
        var latestUserPrompt: (text: String, timestamp: Date)?

        for message in messageObjects {
            guard let type = message["type"] as? String else { continue }
            let normalizedType = type.lowercased()
            let timestamp = parseTimestamp(message["timestamp"])

            if normalizedType == "user" {
                let userText = extractGeminiMessageText(message["content"])
                if !userText.isEmpty {
                    if let current = latestUserPrompt {
                        if timestamp >= current.timestamp {
                            latestUserPrompt = (text: userText, timestamp: timestamp)
                        }
                    } else {
                        latestUserPrompt = (text: userText, timestamp: timestamp)
                    }
                }
                continue
            }

            guard normalizedType == "gemini" || normalizedType == "assistant" || normalizedType == "model" else {
                continue
            }

            if let toolCalls = message["toolCalls"] as? [[String: Any]] {
                for (index, toolCall) in toolCalls.enumerated() {
                    let callId = (toolCall["id"] as? String)
                        ?? "\(message["id"] as? String ?? "gemini-call")-\(index)"
                    let effectiveTimestamp = parseTimestamp(toolCall["timestamp"], fallback: timestamp)
                    let toolName = geminiToolDisplayName(toolCall)
                    let description = geminiToolDescription(toolCall)

                    let preId = "gemini-pre-\(callId)"
                    if !seenToolEvents.contains(preId) {
                        seenToolEvents.insert(preId)
                        toolEvents.append(
                            ParsedToolEvent(
                                id: preId,
                                timestamp: effectiveTimestamp,
                                phase: .pre,
                                tool: toolName,
                                toolUseId: callId,
                                description: description,
                                success: nil
                            )
                        )
                    }

                    if let success = geminiToolCallSuccess(toolCall) {
                        let postId = "gemini-post-\(callId)"
                        if !seenToolEvents.contains(postId) {
                            seenToolEvents.insert(postId)
                            toolEvents.append(
                                ParsedToolEvent(
                                    id: postId,
                                    timestamp: effectiveTimestamp.addingTimeInterval(0.001),
                                    phase: .post,
                                    tool: toolName,
                                    toolUseId: callId,
                                    description: description,
                                    success: success
                                )
                            )
                        }
                    }
                }
            }

            let text = extractGeminiMessageText(message["content"])
            guard !text.isEmpty else { continue }

            let id = (message["id"] as? String)
                ?? "gemini-\(timestamp.timeIntervalSince1970)-\(text.hashValue)"
            if seen.contains(id) { continue }

            seen.insert(id)
            messages.append(AssistantMessage(id: id, text: text, timestamp: timestamp))
        }

        seenMessageIds[sessionId] = seen
        seenToolEventIds[sessionId] = seenToolEvents
        return ParseResult(
            messages: messages,
            toolEvents: toolEvents,
            interrupted: false,
            latestUserPrompt: latestUserPrompt?.text
        )
    }

    private func readNewLines(
        sessionId: String,
        filePath: String,
        initialTailBytes: UInt64? = nil
    ) -> (lines: [String], fileSize: UInt64)? {
        guard FileManager.default.fileExists(atPath: filePath),
              let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return nil
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return nil
        }

        var currentOffset: UInt64
        if let existingOffset = lastFileOffset[sessionId] {
            currentOffset = existingOffset
        } else if let initialTailBytes, fileSize > initialTailBytes {
            currentOffset = fileSize - initialTailBytes
        } else {
            currentOffset = 0
        }

        if fileSize < currentOffset {
            currentOffset = 0
            seenMessageIds[sessionId] = []
            seenToolEventIds[sessionId] = []
            pendingCodexCalls[sessionId] = [:]
        }

        if fileSize == currentOffset {
            return ([], fileSize)
        }

        do {
            try fileHandle.seek(toOffset: currentOffset)
        } catch {
            return nil
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return nil
        }

        let lines = newContent.components(separatedBy: "\n")
        return (lines, fileSize)
    }

    private func resolveSessionFilePath(
        sessionId: String,
        cwd: String,
        source: AIToolSource,
        transcriptPath: String?
    ) -> String? {
        let fileManager = FileManager.default

        if let transcriptPath {
            let trimmed = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && fileManager.fileExists(atPath: trimmed) {
                resolvedSessionFiles[sessionId] = trimmed
                return trimmed
            }
        }

        if let cachedPath = resolvedSessionFiles[sessionId],
           fileManager.fileExists(atPath: cachedPath) {
            return cachedPath
        }

        let discoveredPath: String?
        switch source {
        case .claude:
            discoveredPath = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)
        case .codex:
            discoveredPath = findCodexSessionFile(sessionId: sessionId)
        case .gemini:
            discoveredPath = findGeminiSessionFile(sessionId: sessionId, cwd: cwd)
        }

        guard let discoveredPath else { return nil }
        if source != .claude && !fileManager.fileExists(atPath: discoveredPath) {
            return nil
        }

        resolvedSessionFiles[sessionId] = discoveredPath
        return discoveredPath
    }

    private func findCodexSessionFile(sessionId: String) -> String? {
        let root = URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var bestPath: String?
        var bestDate = Date.distantPast

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard fileURL.lastPathComponent.contains(sessionId) else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values?.isRegularFile == false { continue }

            let modified = values?.contentModificationDate ?? Date.distantPast
            if bestPath == nil || modified > bestDate {
                bestPath = fileURL.path
                bestDate = modified
            }
        }

        return bestPath
    }

    private func findGeminiSessionFile(sessionId: String, cwd: String) -> String? {
        let home = NSHomeDirectory()
        let projectName = (cwd as NSString).lastPathComponent
        let prefix = String(sessionId.prefix(8)).lowercased()

        let preferredDir = URL(fileURLWithPath: "\(home)/.gemini/tmp/\(projectName)/chats", isDirectory: true)
        if let path = latestGeminiChatFile(in: preferredDir, suffixPrefix: prefix, recursive: false) {
            return path
        }

        let fallbackRoot = URL(fileURLWithPath: "\(home)/.gemini/tmp", isDirectory: true)
        return latestGeminiChatFile(in: fallbackRoot, suffixPrefix: prefix, recursive: true)
    }

    private func latestGeminiChatFile(in directory: URL, suffixPrefix: String, recursive: Bool) -> String? {
        let fileManager = FileManager.default
        var bestPath: String?
        var bestDate = Date.distantPast

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "json" else { continue }
                guard fileURL.path.contains("/chats/") else { continue }
                guard fileURL.lastPathComponent.hasSuffix("-\(suffixPrefix).json") else { continue }

                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if values?.isRegularFile == false { continue }

                let modified = values?.contentModificationDate ?? Date.distantPast
                if bestPath == nil || modified > bestDate {
                    bestPath = fileURL.path
                    bestDate = modified
                }
            }

            return bestPath
        }

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for fileURL in urls {
            guard fileURL.pathExtension == "json" else { continue }
            guard fileURL.lastPathComponent.hasSuffix("-\(suffixPrefix).json") else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            if values?.isRegularFile == false { continue }

            let modified = values?.contentModificationDate ?? Date.distantPast
            if bestPath == nil || modified > bestDate {
                bestPath = fileURL.path
                bestDate = modified
            }
        }

        return bestPath
    }

    private func parseTimestamp(_ rawValue: Any?) -> Date {
        guard let rawString = rawValue as? String else { return Date() }
        if let parsed = Self.isoFormatterWithFractional.date(from: rawString) {
            return parsed
        }
        if let parsed = Self.isoFormatter.date(from: rawString) {
            return parsed
        }
        return Date()
    }

    private func parseTimestamp(_ rawValue: Any?, fallback: Date) -> Date {
        guard let rawString = rawValue as? String else { return fallback }
        if let parsed = Self.isoFormatterWithFractional.date(from: rawString) {
            return parsed
        }
        if let parsed = Self.isoFormatter.date(from: rawString) {
            return parsed
        }
        return fallback
    }

    private func parseJSONObjectString(_ raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private func codexCallSucceeded(payload: [String: Any], output: String?) -> Bool {
        if let isError = payload["is_error"] as? Bool {
            return !isError
        }

        guard let output else { return true }
        if output.contains("Process exited with code 0") {
            return true
        }
        if output.range(of: #"Process exited with code [1-9][0-9]*"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private func codexToolDisplayName(functionName: String?) -> String {
        guard let functionName else { return "Bash" }

        switch functionName {
        case "exec_command", "write_stdin":
            return "Bash"
        case "apply_patch":
            return "Edit"
        case "multi_tool_use.parallel":
            return "Task"
        case "update_plan":
            return "Plan"
        case "spawn_agent", "send_input", "wait", "close_agent", "resume_agent":
            return "Task"
        case "view_image":
            return "Read"
        default:
            return functionName
        }
    }

    private func codexToolDescription(functionName: String?, arguments: [String: Any]?) -> String? {
        guard let functionName else { return nil }

        switch functionName {
        case "exec_command":
            if let command = arguments?["cmd"] as? String {
                return summarizeInline(command)
            }
        case "write_stdin":
            if let chars = arguments?["chars"] as? String, !chars.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "stdin: \(summarizeInline(chars))"
            }
        case "multi_tool_use.parallel":
            if let toolUses = arguments?["tool_uses"] as? [[String: Any]] {
                let names = toolUses.compactMap { $0["recipient_name"] as? String }
                if !names.isEmpty {
                    return "Parallel: \(names.joined(separator: ", "))"
                }
            }
        default:
            break
        }

        if let arguments {
            if let first = firstStringValue(in: arguments) {
                return summarizeInline(first)
            }
        }

        return nil
    }

    private func geminiToolDisplayName(_ toolCall: [String: Any]) -> String {
        if let displayName = toolCall["displayName"] as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        let name = (toolCall["name"] as? String) ?? "Tool"
        switch name {
        case "read_file": return "Read"
        case "write_file": return "Write"
        case "edit_file": return "Edit"
        case "list_directory": return "ReadFolder"
        case "search_file_content": return "Grep"
        case "run_shell_command": return "Bash"
        default: return name
        }
    }

    private func geminiToolDescription(_ toolCall: [String: Any]) -> String? {
        if let args = toolCall["args"] as? [String: Any] {
            if let path = args["file_path"] as? String {
                return "Reading \(path)"
            }
            if let path = args["dir_path"] as? String {
                return "Reading \(path)"
            }
            if let pattern = args["pattern"] as? String {
                return "Searching: \(pattern)"
            }
            if let command = args["command"] as? String {
                return summarizeInline(command)
            }
            if let first = firstStringValue(in: args) {
                return summarizeInline(first)
            }
        }
        if let display = toolCall["resultDisplay"] as? String,
           !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summarizeInline(display)
        }
        return nil
    }

    private func geminiToolCallSuccess(_ toolCall: [String: Any]) -> Bool? {
        if let status = (toolCall["status"] as? String)?.lowercased() {
            switch status {
            case "success", "completed":
                return true
            case "error", "failed", "cancelled", "canceled":
                return false
            case "running", "pending", "in_progress":
                return nil
            default:
                break
            }
        }

        if let result = toolCall["result"] as? [Any], !result.isEmpty {
            return true
        }

        return nil
    }

    private func firstStringValue(in dictionary: [String: Any]) -> String? {
        for value in dictionary.values {
            if let string = value as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
            if let nested = value as? [String: Any],
               let nestedString = firstStringValue(in: nested) {
                return nestedString
            }
        }
        return nil
    }

    private func summarizeInline(_ text: String, maxLength: Int = 150) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maxLength else { return compact }
        let index = compact.index(compact.startIndex, offsetBy: maxLength)
        return String(compact[..<index]) + "..."
    }

    private func extractCodexAssistantText(from payload: [String: Any]) -> String {
        extractCodexMessageText(from: payload)
    }

    private func extractCodexMessageText(from payload: [String: Any]) -> String {
        var textParts: [String] = []

        if let content = payload["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                textParts.append(trimmed)
            }
        } else if let contentArray = payload["content"] as? [[String: Any]] {
            for block in contentArray {
                guard let blockType = block["type"] as? String else { continue }
                if blockType == "output_text" ||
                    blockType == "text" ||
                    blockType == "markdown" ||
                    blockType == "input_text" {
                    if let text = block["text"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            textParts.append(trimmed)
                        }
                    }
                }
            }
        }

        return textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractGeminiMessageText(_ content: Any?) -> String {
        if let text = content as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let dict = content as? [String: Any] {
            if let text = dict["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let nested = dict["content"] as? String {
                return nested.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let array = content as? [[String: Any]] {
            let parts = array.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
