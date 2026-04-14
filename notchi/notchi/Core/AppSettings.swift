import Foundation

struct AppSettings {
    static let hideSpriteWhenIdleKey = "hideSpriteWhenIdle"

    private static let notificationSoundKey = "notificationSound"
    private static let isMutedKey = "isMuted"
    private static let previousSoundKey = "previousNotificationSound"
    private static let isUsageEnabledKey = "isUsageEnabled"
    private static let disabledToolsKey = "disabledTools"
    private static let claudeUsageRecoverySnapshotKey = "claudeUsageRecoverySnapshot"
    private static let codexLastIngestAtKey = "codexLastIngestAt"
    private static let claudeExtraUsageObservationKey = "claudeExtraUsageObservation"

    static func isToolEnabled(_ source: AIToolSource) -> Bool {
        let disabled = UserDefaults.standard.stringArray(forKey: disabledToolsKey) ?? []
        return !disabled.contains(source.rawValue)
    }

    static func setToolEnabled(_ source: AIToolSource, _ enabled: Bool) {
        var disabled = UserDefaults.standard.stringArray(forKey: disabledToolsKey) ?? []
        if enabled {
            disabled.removeAll { $0 == source.rawValue }
        } else if !disabled.contains(source.rawValue) {
            disabled.append(source.rawValue)
        }
        UserDefaults.standard.set(disabled, forKey: disabledToolsKey)
    }

    static var isUsageEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isUsageEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: isUsageEnabledKey) }
    }

    static var hideSpriteWhenIdle: Bool {
        get { UserDefaults.standard.bool(forKey: hideSpriteWhenIdleKey) }
        set { UserDefaults.standard.set(newValue, forKey: hideSpriteWhenIdleKey) }
    }

    static var claudeUsageRecoverySnapshot: ClaudeUsageRecoverySnapshot? {
        get {
            guard let data = UserDefaults.standard.data(forKey: claudeUsageRecoverySnapshotKey) else {
                return nil
            }
            return try? JSONDecoder().decode(ClaudeUsageRecoverySnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: claudeUsageRecoverySnapshotKey)
            } else {
                UserDefaults.standard.removeObject(forKey: claudeUsageRecoverySnapshotKey)
            }
        }
    }

    static var codexLastIngestAt: Date? {
        get { UserDefaults.standard.object(forKey: codexLastIngestAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: codexLastIngestAtKey) }
    }

    static var claudeExtraUsageObservation: ClaudeExtraUsageObservation? {
        get {
            guard let data = UserDefaults.standard.data(forKey: claudeExtraUsageObservationKey) else {
                return nil
            }
            return try? JSONDecoder().decode(ClaudeExtraUsageObservation.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: claudeExtraUsageObservationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: claudeExtraUsageObservationKey)
            }
        }
    }

    static var anthropicApiKey: String? {
        get { KeychainManager.getAnthropicApiKey(allowInteraction: true) }
        set { KeychainManager.setAnthropicApiKey(newValue) }
    }

    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: notificationSoundKey),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .purr
            }
            return sound
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: notificationSoundKey)
        }
    }

    static var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: isMutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: isMutedKey) }
    }

    static func toggleMute() {
        if isMuted {
            notificationSound = previousSound ?? .purr
            isMuted = false
        } else {
            previousSound = notificationSound
            notificationSound = .none
            isMuted = true
        }
    }

    private static var previousSound: NotificationSound? {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: previousSoundKey) else {
                return nil
            }
            return NotificationSound(rawValue: rawValue)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: previousSoundKey)
        }
    }
}
