import SwiftUI

enum AIToolSource: String, CaseIterable {
    case claude, gemini, codex

    init(rawString: String) {
        let normalized = rawString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "claude", "claudecode", "claude-code", "claude code":
            self = .claude
        case "gemini", "geminicli", "gemini-cli", "gemini cli":
            self = .gemini
        case "codex", "codexcli", "codex-cli", "codex cli":
            self = .codex
        default:
            if normalized.contains("codex") {
                self = .codex
            } else if normalized.contains("gemini") {
                self = .gemini
            } else if normalized.contains("claude") {
                self = .claude
            } else {
                self = .claude
            }
        }
    }

    var displayName: String {
        switch self {
        case .claude:   return "Claude Code"
        case .gemini:   return "Gemini CLI"
        case .codex:    return "Codex CLI"
        }
    }

    var character: SpriteCharacter {
        switch self {
        case .claude:   return .notchi
        case .gemini:   return .gemmy
        case .codex:    return .codey
        }
    }

    var badgeColor: Color {
        switch self {
        case .claude:   return Color(red: 0.8, green: 0.6, blue: 1.0)
        case .gemini:   return Color(red: 0.3, green: 0.7, blue: 1.0)
        case .codex:    return Color(red: 0.3, green: 0.9, blue: 0.6)
        }
    }
}
