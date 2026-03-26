<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Notchi 1.0.1

A reliability and polish update focused on usage tracking, quieter notifications, and smoother updates.

## Automatic Updates

Notchi now uses Sparkle's standard updater with background update checks and release notes. New versions download automatically, and Notchi will prompt when a relaunch is needed.

## Usage Tracking

The usage bar is much more reliable in edge cases that previously caused stale or missing data.

- Better recovery after rate limits and expired credentials
- Better compatibility with enterprise and work accounts
- Usage polling now recovers properly after sleep and wake
- Recovery state is preserved more reliably across relaunches

## Sound and UI Polish

- Notification sounds are better throttled during busy sessions
- Non-interactive sessions like `claude -p` stay quiet
- Focus detection works better across more terminals and editors
- Retry and reconnect actions in the usage bar are easier to use
- Update status in Settings is clearer, with a subtle reminder when an update is pending
