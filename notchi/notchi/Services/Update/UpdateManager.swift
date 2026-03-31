import Combine
import Sparkle

struct UpdateFailurePresentation: Equatable {
    let label: String

    init(label: String = "Try again") {
        self.label = label
    }
}

/// Update state published to UI
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case downloading(progress: Double)
    case readyToInstall(version: String)
    case error(UpdateFailurePresentation)
}

/// Observable update manager that mirrors Sparkle state into SwiftUI.
/// The real install/relaunch flow is handled by Sparkle's standard UI.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let noUpdateErrorCode = 1001
    static let installationCanceledErrorCode = 4007

    @Published var state: UpdateState = .idle
    @Published var hasPendingUpdate: Bool = false

    private var resetTask: Task<Void, Never>?

    private var updater: SPUUpdater?

    private init() {}

    func setUpdater(_ updater: SPUUpdater) {
        self.updater = updater
    }

    // MARK: - Public (UI actions)

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        resetTask?.cancel()
        beginChecking()
        updater.checkForUpdates()
    }

    func beginChecking() {
        state = .checking
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

    func updateError() {
        state = .error(UpdateFailurePresentation())
    }

    func finishUpdateSession() {
        if case .checking = state {
            state = .idle
        }
    }

    func clearTransientStatus() {
        guard state.isTransientInlineStatus else { return }
        state = .idle
    }

    var shouldHandleUpdaterErrorInline: Bool {
        if case .checking = state {
            return true
        }

        return false
    }

    static func shouldIgnoreAbortError(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain &&
            (error.code == noUpdateErrorCode || error.code == installationCanceledErrorCode)
    }

    private func clearPendingUpdate(showIdleImmediately: Bool = true) {
        hasPendingUpdate = false

        if showIdleImmediately {
            state = .idle
        }
    }
}

private extension UpdateState {
    var isTransientInlineStatus: Bool {
        switch self {
        case .upToDate, .error(_):
            return true
        default:
            return false
        }
    }
}
