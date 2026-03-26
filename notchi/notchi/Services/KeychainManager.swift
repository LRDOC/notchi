import Foundation
import Security

struct ClaudeOAuthCredentials: Equatable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: Set<String>
}

enum KeychainManager {
    private static let claudeCodeService = "Claude Code-credentials"
    private static let notchiService = "com.ruban.notchi"
    private static let anthropicApiKeyAccount = "anthropicApiKey"
    private static let cachedOAuthTokenAccount = "cachedOAuthToken"
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoBasic = ISO8601DateFormatter()

    static func getAccessToken() -> String? {
        readAndCacheAccessToken(allowInteraction: true)
    }

    static func refreshAccessTokenSilently() -> String? {
        readAndCacheAccessToken(allowInteraction: false)
    }

    // MARK: - Anthropic API Key

    static func getAnthropicApiKey() -> String? {
        readString(service: notchiService, account: anthropicApiKeyAccount)
    }

    static func setAnthropicApiKey(_ key: String?) {
        if let key, !key.isEmpty {
            saveString(key, service: notchiService, account: anthropicApiKeyAccount)
        } else {
            deleteItem(service: notchiService, account: anthropicApiKeyAccount)
        }
    }

    // MARK: - Cached OAuth Token

    static func getCachedOAuthToken() -> String? {
        readString(service: notchiService, account: cachedOAuthTokenAccount)
    }

    static func cacheOAuthToken(_ token: String) {
        saveString(token, service: notchiService, account: cachedOAuthTokenAccount)
    }

    static func clearCachedOAuthToken() {
        deleteItem(service: notchiService, account: cachedOAuthTokenAccount)
    }

    // MARK: - Claude Code Credentials

    private static func readAndCacheAccessToken(allowInteraction: Bool) -> String? {
        guard let credentials = getOAuthCredentials(allowInteraction: allowInteraction) else {
            return nil
        }
        cacheOAuthToken(credentials.accessToken)
        return credentials.accessToken
    }

    static func getOAuthCredentials(allowInteraction: Bool) -> ClaudeOAuthCredentials? {
        guard let json = readClaudeCodeKeychain(allowInteraction: allowInteraction) else {
            return nil
        }
        return decodeClaudeOAuthCredentials(from: json)
    }

    private static func readClaudeCodeKeychain(allowInteraction: Bool) -> [String: Any]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    static func decodeClaudeOAuthCredentials(from data: Data) -> ClaudeOAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decodeClaudeOAuthCredentials(from: json)
    }

    static func decodeClaudeOAuthCredentials(from json: [String: Any]) -> ClaudeOAuthCredentials? {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let rawToken = oauth["accessToken"] as? String else {
            return nil
        }

        let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return nil
        }

        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: parseExpiresAt(from: oauth["expiresAt"] ?? oauth["expires_at"]),
            scopes: parseScopes(from: oauth["scopes"])
        )
    }

    private static func parseScopes(from rawValue: Any?) -> Set<String> {
        if let scopes = rawValue as? [String] {
            return Set(scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }

        if let scopeString = rawValue as? String {
            let separators = CharacterSet(charactersIn: ", ")
            let scopes = scopeString
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Set(scopes)
        }

        return []
    }

    private static func parseExpiresAt(from rawValue: Any?) -> Date? {
        switch rawValue {
        case let date as Date:
            return date
        case let number as NSNumber:
            return parseEpoch(number.doubleValue)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let epoch = Double(trimmed) {
                return parseEpoch(epoch)
            }
            return isoFractional.date(from: trimmed) ?? isoBasic.date(from: trimmed)
        default:
            return nil
        }
    }

    private static func parseEpoch(_ value: Double) -> Date {
        let seconds = value > 1_000_000_000_000 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Generic Keychain Helpers

    private static func readString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private static func saveString(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)

        // Try to update existing item first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func deleteItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
