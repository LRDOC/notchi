import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "CodexHookInstaller")

/// Installs Notchi hooks for OpenAI Codex CLI.
/// Current Codex versions expose post-turn notifications via `notify` in
/// ~/.codex/config.toml. Notchi subscribes by registering its hook script as a
/// notify command.
struct CodexHookInstaller: HookInstallerProtocol {

    static let toolName = "Codex CLI"
    private static var notifySupportCache: Bool?

    static var isToolAvailable: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex").path
        )
    }

    @discardableResult
    static func installIfNeeded() -> HookInstallResult {
        guard isToolAvailable else {
            return .toolNotFound
        }

        if let issue = compatibilityIssue() {
            let err = NSError(
                domain: "CodexHookInstaller",
                code: -4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        issue
                ]
            )
            return .failed(err)
        }

        let wasInstalled = isInstalled()

        let codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let hooksDir = codexDir.appendingPathComponent("hooks")
        let hookScript = hooksDir.appendingPathComponent("notchi-hook.sh")
        let configTOML = codexDir.appendingPathComponent("config.toml")
        let hooksJSON = codexDir.appendingPathComponent("hooks.json")

        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create .codex/hooks directory: \(error.localizedDescription)")
            return .failed(error)
        }

        if let bundled = Bundle.main.url(forResource: "notchi-hook-codex", withExtension: "sh") {
            do {
                try? FileManager.default.removeItem(at: hookScript)
                try FileManager.default.copyItem(at: bundled, to: hookScript)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: hookScript.path
                )
                logger.info("Installed Codex hook script to \(hookScript.path, privacy: .public)")
            } catch {
                logger.error("Failed to install Codex hook script: \(error.localizedDescription)")
                return .failed(error)
            }
        } else {
            let err = NSError(domain: "CodexHookInstaller", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "notchi-hook-codex.sh not found in bundle"])
            return .failed(err)
        }

        let notifyUpdated = upsertNotifyCommand(in: configTOML, command: hookScript.path)

        // Best-effort cleanup of older/invalid integration paths.
        _ = removeNotchiCodexHooksFlag(from: configTOML)
        removeNotchiCommandFromHooksJSON(at: hooksJSON)
        _ = removeLegacyHookBlocks(from: configTOML)

        guard notifyUpdated else {
            return .failed(NSError(
            domain: "CodexHookInstaller", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to update Codex hooks configuration"]
            ))
        }

        return wasInstalled ? .alreadyInstalled : .installed
    }

    static func isInstalled() -> Bool {
        guard compatibilityIssue() == nil else {
            return false
        }

        let codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let hookScript = codexDir.appendingPathComponent("hooks/notchi-hook.sh")
        let configTOML = codexDir.appendingPathComponent("config.toml")
        let hooksJSON = codexDir.appendingPathComponent("hooks.json")

        let hasScript = FileManager.default.fileExists(atPath: hookScript.path)
        let hasNotifyCommand = configContainsNotchiNotifyCommand(in: configTOML)

        // Backward compatibility for users with pre-notify installs.
        let hasHooksJSONEntry = hooksJSONContainsNotchiCommand(at: hooksJSON)
        let hasLegacyConfig = configContainsLegacyNotchiHook(in: configTOML)

        return hasScript && (hasNotifyCommand || hasHooksJSONEntry || hasLegacyConfig)
    }

    static func uninstall() {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let hookScript = codexDir.appendingPathComponent("hooks/notchi-hook.sh")
        let hooksJSON = codexDir.appendingPathComponent("hooks.json")
        let configTOML = codexDir.appendingPathComponent("config.toml")

        try? FileManager.default.removeItem(at: hookScript)
        _ = removeNotchiNotifyCommand(from: configTOML)
        _ = removeNotchiCodexHooksFlag(from: configTOML)
        removeNotchiCommandFromHooksJSON(at: hooksJSON)
        _ = removeLegacyHookBlocks(from: configTOML)
        logger.info("Uninstalled Codex Notchi hooks")
    }

    static func compatibilityIssue() -> String? {
        guard isToolAvailable else { return nil }
        guard !supportsNotifyCommand() else { return nil }
        return "Installed Codex CLI does not support command notifications in config.toml. Update Codex CLI to a version that supports `notify = [\"<command>\"]`."
    }

    private static func hooksJSONContainsNotchiCommand(at hooksJSONURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: hooksJSONURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for eventValue in hooks.values {
            guard let definitions = eventValue as? [[String: Any]] else { continue }
            for definition in definitions {
                guard let entries = definition["hooks"] as? [[String: Any]] else { continue }
                if entries.contains(where: { ($0["command"] as? String)?.contains("notchi-hook.sh") == true }) {
                    return true
                }
            }
        }

        return false
    }

    private static func supportsNotifyCommand() -> Bool {
        if let cached = notifySupportCache {
            return cached
        }

        let fileManager = FileManager.default
        guard let tempRoot = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: fileManager.homeDirectoryForCurrentUser,
            create: true
        ) else {
            notifySupportCache = false
            return false
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        let codexDir = tempRoot.appendingPathComponent(".codex")
        do {
            try fileManager.createDirectory(at: codexDir, withIntermediateDirectories: true)
            try #"notify = ["/tmp/notchi-noop"]"#.write(
                to: codexDir.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            notifySupportCache = false
            return false
        }

        guard !Thread.isMainThread else {
            notifySupportCache = false
            return false
        }

        guard let codexExecutable = codexExecutablePath() else {
            notifySupportCache = false
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexExecutable)
        process.arguments = ["features", "list"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempRoot.path
        process.environment = environment
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            notifySupportCache = false
            return false
        }
        process.waitUntilExit()

        // Even if the process exits 0, check stderr for config parse errors.
        // Codex may print "invalid type: sequence, expected a boolean" and
        // continue running rather than returning a non-zero exit code.
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        let hasConfigError = stderrText.contains("invalid type") || stderrText.contains("Error loading config")

        let supported = process.terminationStatus == 0 && !hasConfigError
        notifySupportCache = supported
        return supported
    }

    private static func codexExecutablePath() -> String? {
        let fileManager = FileManager.default

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/codex"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        let fallbackCandidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return fallbackCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private static func removeNotchiCommandFromHooksJSON(at hooksJSONURL: URL) {
        guard let data = try? Data(contentsOf: hooksJSONURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (eventName, value) in hooks {
            guard var definitions = value as? [[String: Any]] else { continue }

            definitions = definitions.compactMap { definition in
                guard var entries = definition["hooks"] as? [[String: Any]] else {
                    return definition
                }
                entries.removeAll { ($0["command"] as? String)?.contains("notchi-hook.sh") == true }
                if entries.isEmpty {
                    return nil
                }
                var updated = definition
                updated["hooks"] = entries
                return updated
            }

            if definitions.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = definitions
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? output.write(to: hooksJSONURL)
        }
    }

    private static func configContainsNotchiNotifyCommand(in configURL: URL) -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return false
        }
        guard let match = firstNotifyArrayMatch(in: content) else {
            return false
        }
        let commands = parseTomlStringArray(match.body)
        return commands.contains { $0.contains("notchi-hook.sh") }
    }

    private static func upsertNotifyCommand(in configURL: URL, command: String) -> Bool {
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = upsertingNotifyCommand(in: existing, command: command)

        do {
            try updated.write(to: configURL, atomically: true, encoding: .utf8)
            logger.info("Updated Codex notify command in \(configURL.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to write Codex config.toml: \(error.localizedDescription)")
            return false
        }
    }

    private static func removeNotchiNotifyCommand(from configURL: URL) -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return true
        }

        let updated = removingNotifyCommand(in: content)
        guard updated != content else { return true }

        do {
            try updated.write(to: configURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.error("Failed removing Codex notify command: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes lines that older Notchi versions incorrectly wrote inside TOML sections:
    /// - `codex_hooks = true` inside [features]
    /// - `notify = [...notchi-hook.sh...]` inside any [section] (must be top-level)
    /// - Stale `# Notchi hooks` and `# Notchi notifications` comments inside sections
    @discardableResult
    private static func removeNotchiCodexHooksFlag(from configURL: URL) -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return true
        }

        let lines = content.components(separatedBy: "\n")
        var output: [String] = []
        var insideSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track whether we are inside a [section] block.
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") && trimmed.hasSuffix("]") {
                insideSection = true
            } else if trimmed.hasPrefix("[[") {
                insideSection = true
            }

            if insideSection {
                // Drop legacy Notchi lines that must only appear at top level.
                if trimmed == "codex_hooks = true"
                    || trimmed == "# Notchi hooks"
                    || trimmed == "# Notchi notifications"
                    || (trimmed.hasPrefix("notify") && trimmed.contains("notchi-hook.sh")) {
                    continue
                }
            }
            output.append(line)
        }

        let updated = output.joined(separator: "\n")
        guard updated != content else { return true }

        do {
            let cleaned = cleanupBlankLines(in: updated)
            try cleaned.write(to: configURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.error("Failed to remove codex_hooks flag: \(error.localizedDescription)")
            return false
        }
    }

    private static func configContainsLegacyNotchiHook(in configURL: URL) -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return false
        }
        let legacyPattern = #"(?s)\[\[hooks\.[^\]]+\]\].*?notchi-hook\.sh"#
        return content.range(of: legacyPattern, options: .regularExpression) != nil
    }

    private static func upsertingNotifyCommand(in content: String, command: String) -> String {
        if let match = firstNotifyArrayMatch(in: content) {
            var commands = parseTomlStringArray(match.body)
            if !commands.contains(where: { $0.contains("notchi-hook.sh") || $0 == command }) {
                commands.append(command)
            }
            let replacement = renderNotifyLine(commands)
            return content.replacingCharacters(in: match.fullRange, with: replacement)
        }

        // Insert notify BEFORE the first section header so it stays at the top level.
        // Appending to the end would place it inside the last [section] block.
        let newLine = "# Notchi notifications\n\(renderNotifyLine([command]))\n"
        if let sectionRange = firstSectionHeaderRange(in: content) {
            return content.replacingCharacters(
                in: sectionRange.lowerBound..<sectionRange.lowerBound,
                with: newLine + "\n"
            )
        }

        var output = content
        if !output.isEmpty && !output.hasSuffix("\n") { output.append("\n") }
        if !output.isEmpty { output.append("\n") }
        output.append(newLine)
        return output
    }

    /// Returns the start of the first `[section]` header line, or nil if none found.
    private static func firstSectionHeaderRange(in content: String) -> Range<String.Index>? {
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let regex = try? NSRegularExpression(pattern: #"^\[(?!\[)"#, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: content, range: nsRange),
              let range = Range(match.range, in: content) else {
            return nil
        }
        // Walk back to the start of the line
        let lineStart = content[content.startIndex..<range.lowerBound]
            .lastIndex(of: "\n")
            .map { content.index(after: $0) } ?? content.startIndex
        return lineStart..<range.upperBound
    }

    private static func removingNotifyCommand(in content: String) -> String {
        guard let match = firstNotifyArrayMatch(in: content) else {
            return content
        }

        var commands = parseTomlStringArray(match.body)
        commands.removeAll { $0.contains("notchi-hook.sh") }

        if commands.isEmpty {
            var updated = content
            updated.replaceSubrange(match.fullRange, with: "")
            return cleanupBlankLines(in: updated)
        }

        let replacement = renderNotifyLine(commands)
        return content.replacingCharacters(in: match.fullRange, with: replacement)
    }

    nonisolated private static func renderNotifyLine(_ commands: [String]) -> String {
        let quoted = commands.map(tomlQuote).joined(separator: ", ")
        return "notify = [\(quoted)]"
    }

    nonisolated private static func tomlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func cleanupBlankLines(in content: String) -> String {
        var output = content
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output
    }

    private static func parseTomlStringArray(_ rawArrayBody: String) -> [String] {
        let nsRange = NSRange(rawArrayBody.startIndex..<rawArrayBody.endIndex, in: rawArrayBody)
        guard let regex = try? NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)""#) else {
            return []
        }

        let matches = regex.matches(in: rawArrayBody, range: nsRange)
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: rawArrayBody) else {
                return nil
            }
            return unescapeTomlString(String(rawArrayBody[range]))
        }
    }

    private static func unescapeTomlString(_ raw: String) -> String {
        var output = ""
        var isEscaping = false

        for char in raw {
            if isEscaping {
                switch char {
                case "n":
                    output.append("\n")
                case "t":
                    output.append("\t")
                case "\"":
                    output.append("\"")
                case "\\":
                    output.append("\\")
                default:
                    output.append(char)
                }
                isEscaping = false
                continue
            }

            if char == "\\" {
                isEscaping = true
            } else {
                output.append(char)
            }
        }

        if isEscaping {
            output.append("\\")
        }

        return output
    }

    private static func firstNotifyArrayMatch(in content: String) -> (fullRange: Range<String.Index>, body: String)? {
        // Only match notify at the TOP LEVEL — i.e., before the first [section] header.
        // A notify = [...] inside [features] is a boolean field and must not be touched.
        let searchNSRange: NSRange
        if let sectionRange = firstSectionHeaderRange(in: content) {
            let sectionOffset = content.distance(from: content.startIndex, to: sectionRange.lowerBound)
            searchNSRange = NSRange(location: 0, length: sectionOffset)
        } else {
            searchNSRange = NSRange(content.startIndex..<content.endIndex, in: content)
        }

        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)^notify\s*=\s*\[(.*?)\]"#,
            options: [.anchorsMatchLines]
        ),
            let match = regex.firstMatch(in: content, range: searchNSRange),
            let fullRange = Range(match.range(at: 0), in: content),
            let bodyRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return (fullRange, String(content[bodyRange]))
    }

    private static func removeLegacyHookBlocks(from configURL: URL) -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return true
        }

        let lines = content.components(separatedBy: "\n")
        var output: [String] = []
        var pendingBlock: [String] = []
        var inHookBlock = false
        var hookBlockHasNotchiCommand = false

        func flushHookBlock() {
            guard inHookBlock else { return }
            if !hookBlockHasNotchiCommand {
                output.append(contentsOf: pendingBlock)
            }
            pendingBlock.removeAll(keepingCapacity: true)
            inHookBlock = false
            hookBlockHasNotchiCommand = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHookHeader = trimmed.hasPrefix("[[hooks.")
            let isTableHeader = trimmed.hasPrefix("[") && trimmed.hasSuffix("]")

            if isHookHeader {
                flushHookBlock()
                inHookBlock = true
                pendingBlock.append(line)
                continue
            }

            if inHookBlock && isTableHeader {
                flushHookBlock()
                output.append(line)
                continue
            }

            if inHookBlock {
                pendingBlock.append(line)
                if line.contains("notchi-hook.sh") {
                    hookBlockHasNotchiCommand = true
                }
            } else {
                output.append(line)
            }
        }

        flushHookBlock()

        let updated = output.joined(separator: "\n")
        if updated == content {
            return true
        }

        do {
            try updated.write(to: configURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.error("Failed to clean legacy Codex hook blocks: \(error.localizedDescription)")
            return false
        }
    }
}
