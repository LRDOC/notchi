# Notchi

A macOS notch companion that reacts to Claude Code, Gemini CLI, and Codex CLI activity in real-time.

https://github.com/user-attachments/assets/e417bd40-cae8-47c0-998a-905166cf3513

## What it does

- Reacts to CLI agent events in real-time (thinking, working, errors, completions)
- Analyzes conversation sentiment to show emotions (happy, sad, neutral, sob)
- Click to expand and see session usage
- Supports multiple concurrent sessions with individual sprites
- Sound effects for events (optional, auto-muted when terminal is focused)
- Auto-updates via Sparkle

## Install

1. Download `Notchi-x.x.x.dmg` from the [latest GitHub Release](https://github.com/sk-ruban/notchi/releases/latest)
2. Open the DMG and drag Notchi to Applications
3. Launch Notchi — it auto-installs hooks for detected CLIs on first launch
4. A macOS keychain popup will appear asking to access Claude Code's cached OAuth token (used for API usage stats). Click **Always Allow** so it won't prompt again on future launches

   <img src="assets/keychain-popup.png" alt="Keychain access popup" width="450">

5. *(Optional)* Click the notch to expand → open Settings → paste your Anthropic API key. This enables sentiment analysis of your prompts so the mascot reacts emotionally

   <img src="assets/emotion-settings.png" alt="Emotion analysis settings" width="400">

6. Start using your CLI agent and watch Notchi react

## CLI Hook Setup (Claude, Gemini, Codex)

Notchi installs local hook scripts and registers them with each CLI:

- `~/.claude/hooks/notchi-hook.sh`
- `~/.gemini/hooks/notchi-hook.sh`
- `~/.codex/hooks/notchi-hook.sh`

Configuration files Notchi updates:

- Claude Code: Claude hooks config (managed automatically)
- Gemini CLI: `~/.gemini/settings.json`
  - Adds Notchi hooks for lifecycle events
  - Sets `tools.enableHooks = true`
  - Sets `tools.enableMessageBusIntegration = true`
- Codex CLI: `~/.codex/config.toml`
  - Adds top-level `notify = [".../notchi-hook.sh"]`
  - Removes older legacy Notchi Codex hook formats

You can re-run installation from Notchi:

- Expand notch → Settings → `Hooks`

Per-tool status badges:

- `Install`: tool found, hook not installed yet
- `Unsupported`: detected CLI version/config is incompatible
- `Not Found`: CLI config directory not detected on disk
- Toggle enabled: installed and active

## Requirements

- macOS 15.0+ (Sequoia)
- MacBook with notch
- At least one supported CLI installed:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  - [Gemini CLI](https://github.com/google-gemini/gemini-cli) `>= 0.33.0`
  - [Codex CLI](https://github.com/openai/codex)

## How it works

```
CLI Agent --> Hooks (shell scripts) --> Unix Socket --> Event Parser --> State Machine --> Animated Sprites
```

Notchi registers shell script hooks with each detected CLI on launch. When a CLI emits events (tool use, thinking, prompts, session start/end), the hook script sends JSON payloads to a Unix socket. The app parses these events, runs them through a state machine that maps to sprite animations (idle, working, sleeping, compacting, waiting), and uses the Anthropic API to analyze user prompt sentiment for emotional reactions.

Each active session gets its own sprite on the grass island. Clicking expands the notch panel to show a live activity feed, session info, and API usage stats.

## Troubleshooting

### Gemini shows `Unsupported` with `version (unknown)`

1. Confirm CLI version in Terminal:
   - `gemini --version`
2. Upgrade if needed:
   - `brew upgrade gemini-cli`
3. Re-open Notchi Settings and click `Hooks` once to re-install/re-check.

Notes:

- Notchi requires Gemini CLI `0.33.0+` for reliable hook runtime events.
- If Gemini is installed via Homebrew, ensure Homebrew binaries are available in your shell profile.

### Codex shows `Unsupported`

1. Confirm CLI version:
   - `codex --version`
2. Re-open Notchi Settings and click `Hooks` to re-apply `notify` config.
3. Verify `~/.codex/config.toml` contains a top-level `notify = ["...notchi-hook.sh"]`.

### Hooks appear installed but no activity appears

1. Ensure Notchi is running (socket path should exist):
   - `ls -l /tmp/notchi.sock`
2. Trigger a fresh prompt in the CLI (hooks emit on events).
3. Re-run `Hooks` install from Settings.

## Credits

- [Claude Island](https://github.com/farouqaldori/claude-island)
- [Readout](https://readout.org)

## License

MIT
