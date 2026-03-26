import Combine
import Sparkle

/// Update state published to UI
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case downloading(progress: Double)
    case readyToInstall(version: String)
    case error(message: String)
}

/// Observable update manager that mirrors Sparkle state into SwiftUI.
/// The real install/relaunch flow is handled by Sparkle's standard UI.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var state: UpdateState = .idle
    @Published var hasPendingUpdate: Bool = false

    private var resetTask: Task<Void, Never>?

    private var updater: SPUUpdater?

    func setUpdater(_ updater: SPUUpdater) {
        self.updater = updater
    }

    // MARK: - Public (UI actions)

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        resetTask?.cancel()
        state = .checking
        updater.checkForUpdates()
    }

    func updateFound(version: String) {
        hasPendingUpdate = true

        if case .downloading = state {
            return
        }

        state = .updateAvailable(version: version)
    }

    func userMadeChoice(_ choice: SPUUserUpdateChoice, stage: SPUUserUpdateStage, version: String) {
        switch choice {
        case .skip:
            clearPendingUpdate()
        case .dismiss:
            hasPendingUpdate = true
            state = stage == .notDownloaded
                ? .updateAvailable(version: version)
                : .readyToInstall(version: version)
        case .install:
            hasPendingUpdate = true
            if stage == .notDownloaded {
                state = .downloading(progress: 0)
            } else {
                state = .readyToInstall(version: version)
            }
        @unknown default:
            break
        }
    }

    func downloadStarted() {
        hasPendingUpdate = true
        state = .downloading(progress: 0)
    }

    func readyToInstall(version: String) {
        hasPendingUpdate = true
        state = .readyToInstall(version: version)
    }

    func noUpdateFound() {
        clearPendingUpdate(showIdleImmediately: false)
        state = .upToDate
    }

    func updateError(_ message: String) {
        state = .error(message: message)
    }

    func finishUpdateSession() {
        if case .checking = state {
            state = .idle
        }
    }

    func clearInlineNoUpdateStatus() {
        guard case .upToDate = state else { return }
        state = .idle
    }

    private func clearPendingUpdate(showIdleImmediately: Bool = true) {
        hasPendingUpdate = false

        if showIdleImmediately {
            state = .idle
        }
    }
}
