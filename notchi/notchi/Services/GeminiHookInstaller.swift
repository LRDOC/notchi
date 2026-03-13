import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "GeminiHookInstaller")

struct GeminiHookInstaller: HookInstallerProtocol {

    static let toolName = "Gemini CLI"
    // Hooks are not reliably emitted on older Gemini CLI builds (for example 0.16.x).
    // Require a newer runtime where hook events are consistently delivered.
    private static let minimumHookRuntimeVersion = "0.33.0"
    private static var cachedVersion: String?? = nil // nil = unchecked, .some(nil) = not found

    static var isToolAvailable: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini").path
        )
    }

    @discardableResult
    static func installIfNeeded() -> HookInstallResult {
        guard isToolAvailable else {
            return .toolNotFound
        }

        if let issue = compatibilityIssue() {
            let version = installedGeminiVersion() ?? "unknown"
            let err = NSError(
                domain: "GeminiHookInstaller",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        issue
                ]
            )
            logger.error("Gemini hooks unavailable for version \(version, privacy: .public)")
            return .failed(err)
        }

        let wasInstalled = isInstalled()

        let geminiDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
        let hooksDir = geminiDir.appendingPathComponent("hooks")
        let hookScript = hooksDir.appendingPathComponent("notchi-hook.sh")
        let settings = geminiDir.appendingPathComponent("settings.json")

        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create .gemini/hooks directory: \(error.localizedDescription)")
            return .failed(error)
        }

        if let bundled = Bundle.main.url(forResource: "notchi-hook-gemini", withExtension: "sh") {
            do {
                try? FileManager.default.removeItem(at: hookScript)
                try FileManager.default.copyItem(at: bundled, to: hookScript)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: hookScript.path
                )
                logger.info("Installed Gemini hook script to \(hookScript.path, privacy: .public)")
            } catch {
                logger.error("Failed to install Gemini hook script: \(error.localizedDescription)")
                return .failed(error)
            }
        } else {
            let err = NSError(domain: "GeminiHookInstaller", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "notchi-hook-gemini.sh not found in bundle"])
            return .failed(err)
        }

        let success = updateSettings(at: settings, hookScriptPath: hookScript.path)
        if success {
            return wasInstalled ? .alreadyInstalled : .installed
        }
        return .failed(NSError(
            domain: "GeminiHookInstaller", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to update Gemini settings.json"]
        ))
    }

    static func isInstalled() -> Bool {
        guard compatibilityIssue() == nil else { return false }

        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let matchers = value as? [[String: Any]] else { return false }
            return matchers.contains { matcher in
                guard let innerHooks = matcher["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { hook in
                    (hook["command"] as? String)?.contains("notchi-hook.sh") == true
                }
            }
        }
    }

    static func uninstall() {
        let geminiDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini")
        let hookScript = geminiDir.appendingPathComponent("hooks/notchi-hook.sh")
        let settings = geminiDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: hookScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var matchers = value as? [[String: Any]] {
                matchers.removeAll { matcher in
                    guard let innerHooks = matcher["hooks"] as? [[String: Any]] else { return false }
                    return innerHooks.contains { hook in
                        (hook["command"] as? String)?.contains("notchi-hook.sh") == true
                    }
                }
                if matchers.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = matchers
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settings)
        }

        logger.info("Uninstalled Gemini Notchi hooks")
    }

    static func compatibilityIssue() -> String? {
        guard isToolAvailable else { return nil }
        guard !supportsHooksRuntime() else { return nil }
        let version = installedGeminiVersion() ?? "unknown"
        return "Installed Gemini CLI version (\(version)) does not support Notchi hook runtime. Upgrade Gemini CLI to \(minimumHookRuntimeVersion) or newer."
    }

    private static func updateSettings(at settingsURL: URL, hookScriptPath: String) -> Bool {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let command = hookScriptPath
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("BeforeTool",  withMatcher),
            ("AfterTool",   withMatcher),
            ("BeforeAgent", withoutMatcher),
            ("AfterAgent",  withoutMatcher),
            ("BeforeModel", withoutMatcher),
            ("AfterModel",  withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd",  withoutMatcher),
            ("PreCompress", withoutMatcher),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                var didUpdateExisting = false

                existingEvent = existingEvent.map { entry in
                    guard var entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }

                    var entryChanged = false
                    entryHooks = entryHooks.map { hook in
                        guard let rawCommand = hook["command"] as? String,
                              rawCommand.contains("notchi-hook.sh") else {
                            return hook
                        }

                        guard rawCommand != command else { return hook }
                        var updatedHook = hook
                        updatedHook["command"] = command
                        entryChanged = true
                        return updatedHook
                    }

                    guard entryChanged else { return entry }
                    var updatedEntry = entry
                    updatedEntry["hooks"] = entryHooks
                    didUpdateExisting = true
                    return updatedEntry
                }

                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            (h["command"] as? String)?.contains("notchi-hook.sh") == true
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    didUpdateExisting = true
                }

                if didUpdateExisting {
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        // enableHooks defaults to false in Gemini CLI — must be set explicitly
        var tools = json["tools"] as? [String: Any] ?? [:]
        tools["enableHooks"] = true
        tools["enableMessageBusIntegration"] = true
        json["tools"] = tools

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            logger.error("Failed to serialize Gemini settings JSON")
            return false
        }

        do {
            try data.write(to: settingsURL)
            logger.info("Updated Gemini settings.json with Notchi hooks")
            return true
        } catch {
            logger.error("Failed to write Gemini settings.json: \(error.localizedDescription)")
            return false
        }
    }

    private static func supportsHooksRuntime() -> Bool {
        guard let version = installedGeminiVersion() else {
            return false
        }
        return isVersion(version, atLeast: minimumHookRuntimeVersion)
    }

    private static func installedGeminiVersion() -> String? {
        if let cached = cachedVersion {
            return cached
        }

        // Never spawn a subprocess on the main thread — it pumps the run loop
        // and can cause SwiftUI AG graph reentrancy crashes.
        guard !Thread.isMainThread else { return nil }

        guard let geminiExecutable = geminiExecutablePath() else {
            cachedVersion = .some(nil)
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: geminiExecutable)
        process.arguments = ["--version"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            cachedVersion = .some(nil)
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            cachedVersion = .some(nil)
            return nil
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output else {
            cachedVersion = .some(nil)
            return nil
        }

        let versionPattern = #"^\d+(\.\d+){1,3}$"#
        if output.range(of: versionPattern, options: .regularExpression) != nil {
            cachedVersion = .some(output)
            return output
        }
        cachedVersion = .some(nil)
        return nil
    }

    private static func geminiExecutablePath() -> String? {
        let fileManager = FileManager.default

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/gemini"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        let fallbackCandidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
        ]
        return fallbackCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        func parse(_ value: String) -> [Int]? {
            let parts = value.split(separator: ".")
            guard !parts.isEmpty else { return nil }
            let ints = parts.compactMap { Int($0) }
            return ints.count == parts.count ? ints : nil
        }

        guard let lhs = parse(version), let rhs = parse(minimum) else {
            return false
        }

        let count = max(lhs.count, rhs.count)
        for idx in 0..<count {
            let l = idx < lhs.count ? lhs[idx] : 0
            let r = idx < rhs.count ? rhs[idx] : 0
            if l > r { return true }
            if l < r { return false }
        }
        return true
    }
}
