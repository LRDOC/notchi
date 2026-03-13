import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "HookInstallerCoordinator")

struct HookInstallerCoordinator {

    static let all: [any HookInstallerProtocol.Type] = [
        ClaudeHookInstaller.self,
        GeminiHookInstaller.self,
        CodexHookInstaller.self,
    ]

    @discardableResult
    static func installAll() -> [String: HookInstallResult] {
        var results: [String: HookInstallResult] = [:]
        for installer in all {
            let result = installer.installIfNeeded()
            results[installer.toolName] = result
            switch result {
            case .installed:
                logger.info("Installed hooks for \(installer.toolName, privacy: .public)")
            case .alreadyInstalled:
                logger.debug("Hooks already installed for \(installer.toolName, privacy: .public)")
            case .toolNotFound:
                logger.debug("Tool not found: \(installer.toolName, privacy: .public)")
            case .failed(let error):
                logger.error("Failed to install hooks for \(installer.toolName, privacy: .public): \(error.localizedDescription)")
            }
        }
        return results
    }

    static func isAnyInstalled() -> Bool {
        all.contains { $0.isInstalled() }
    }

    static func compatibilityIssues() -> [AIToolSource: String] {
        var issues: [AIToolSource: String] = [:]
        for source in AIToolSource.allCases {
            guard let installer = installer(for: source),
                  let issue = installer.compatibilityIssue() else { continue }
            issues[source] = issue
        }
        return issues
    }

    static func installedTools() -> [AIToolSource] {
        var installed: [AIToolSource] = []
        if ClaudeHookInstaller.isInstalled() { installed.append(.claude) }
        if GeminiHookInstaller.isInstalled() { installed.append(.gemini) }
        if CodexHookInstaller.isInstalled() { installed.append(.codex) }
        return installed
    }

    static func installer(for source: AIToolSource) -> (any HookInstallerProtocol.Type)? {
        switch source {
        case .claude:   return ClaudeHookInstaller.self
        case .gemini:   return GeminiHookInstaller.self
        case .codex:    return CodexHookInstaller.self
        }
    }

    static func isInstalled(for source: AIToolSource) -> Bool {
        installer(for: source)?.isInstalled() ?? false
    }
}
