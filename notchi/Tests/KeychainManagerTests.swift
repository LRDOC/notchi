import Foundation
import XCTest
@testable import notchi

final class KeychainManagerTests: XCTestCase {
    func testDecodeClaudeOAuthCredentialsWithScopesAndExpiry() throws {
        let expiresAt = "2099-01-01T01:00:00Z"
        let data = makeCredentialPayload(
            accessToken: "token-123",
            expiresAt: expiresAt,
            scopes: ["user:profile", "openid"]
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.accessToken, "token-123")
        XCTAssertEqual(credentials.scopes, Set(["openid", "user:profile"]))
        XCTAssertEqual(
            credentials.expiresAt,
            ISO8601DateFormatter().date(from: expiresAt)
        )
    }

    func testDecodeClaudeOAuthCredentialsAllowsMissingUserProfileScope() throws {
        let data = makeCredentialPayload(
            accessToken: "token-123",
            scopes: ["openid"]
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.scopes, Set(["openid"]))
        XCTAssertFalse(credentials.scopes.contains("user:profile"))
    }

    func testDecodeClaudeOAuthCredentialsParsesExpiredEpochMetadata() throws {
        let data = makeCredentialPayload(
            accessToken: "token-123",
            expiresAt: 1
        )

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1))
    }

    func testDecodeClaudeOAuthCredentialsAllowsAbsentOptionalMetadata() throws {
        let data = makeCredentialPayload(accessToken: "token-123")

        let credentials = try XCTUnwrap(KeychainManager.decodeClaudeOAuthCredentials(from: data))

        XCTAssertEqual(credentials.accessToken, "token-123")
        XCTAssertNil(credentials.expiresAt)
        XCTAssertTrue(credentials.scopes.isEmpty)
    }

    private func makeCredentialPayload(
        accessToken: String,
        expiresAt: Any? = nil,
        scopes: [String]? = nil
    ) -> Data {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
        ]
        if let expiresAt {
            oauth["expiresAt"] = expiresAt
        }
        if let scopes {
            oauth["scopes"] = scopes
        }

        let payload: [String: Any] = [
            "claudeAiOauth": oauth,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
