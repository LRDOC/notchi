import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    private(set) var currentState: NotchiState = .idle
    let stats = SessionStats()

    private var sleepTimer: Task<Void, Never>?

    private static let sleepDelay: Duration = .seconds(300)

    private init() {
        startSleepTimer()
    }

    func handleEvent(_ event: HookEvent) {
        cancelSleepTimer()
        stats.updateProcessingState(status: event.status)

        let isDone = event.status == "waiting_for_input"

        switch event.event {
        case "UserPromptSubmit":
            transition(to: .thinking)

        case "PreCompact":
            transition(to: .compacting)

        case "SessionStart":
            stats.startSession()
            transition(to: .thinking)

        case "PreToolUse":
            let toolInput = event.toolInput?.mapValues { $0.value }
            stats.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            transition(to: .thinking)
            if isDone {
                SoundService.shared.playNotificationSound()
            }

        case "PermissionRequest":
            transition(to: .thinking)
            SoundService.shared.playNotificationSound()

        case "PostToolUse":
            let success = event.status != "error"
            stats.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)

        case "Stop":
            transition(to: .happy)
            SoundService.shared.playNotificationSound()

        case "SubagentStop":
            transition(to: .happy)

        case "SessionEnd":
            stats.endSession()
            transition(to: .idle)

        default:
            if isDone && currentState != .idle {
                transition(to: .happy)
                SoundService.shared.playNotificationSound()
            }
        }

        startSleepTimer()
    }

    private func transition(to newState: NotchiState) {
        guard currentState != newState else { return }
        logger.info("State: \(self.currentState.rawValue, privacy: .public) → \(newState.rawValue, privacy: .public)")
        currentState = newState
    }

    private func startSleepTimer() {
        sleepTimer = Task {
            try? await Task.sleep(for: Self.sleepDelay)
            guard !Task.isCancelled else { return }
            transition(to: .sleeping)
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.cancel()
        sleepTimer = nil
    }
}
