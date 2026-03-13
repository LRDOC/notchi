enum SpriteCharacter: String, CaseIterable {
    case notchi   // Claude Code
    case gemmy    // Gemini CLI
    case codey    // Codex CLI

    var spritePrefix: String { rawValue }
}
