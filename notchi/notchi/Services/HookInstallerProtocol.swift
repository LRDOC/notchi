import Foundation

enum HookInstallResult {
    case installed
    case alreadyInstalled
    case toolNotFound
    case failed(Error)
}

protocol HookInstallerProtocol {
    static var toolName: String { get }
    static var isToolAvailable: Bool { get }
    @discardableResult
    static func installIfNeeded() -> HookInstallResult
    static func isInstalled() -> Bool
    static func compatibilityIssue() -> String?
    static func uninstall()
}

extension HookInstallerProtocol {
    static func compatibilityIssue() -> String? { nil }
}
