import XCTest
@testable import notchi

final class UsageBarViewTests: XCTestCase {
    func testPlaceholderShowsOnlyWhenTrulyDisconnected() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: false
        )

        XCTAssertTrue(view.shouldShowConnectPlaceholder)
    }

    func testPlaceholderDoesNotHideRealUsageState() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: nil,
            isStale: false,
            recoveryAction: .none,
            isEnabled: false
        )

        XCTAssertFalse(view.shouldShowConnectPlaceholder)
    }

    func testPlaceholderDoesNotHideReconnectState() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Token expired",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .reconnect,
            isEnabled: false
        )

        XCTAssertFalse(view.shouldShowConnectPlaceholder)
    }

    func testUsagePresentRetryStateIsNotTappable() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: "Updating soon",
            isStale: true,
            recoveryAction: .retry,
            isEnabled: true
        )

        XCTAssertFalse(view.shouldAllowTapAction)
    }

    func testUsagePresentReconnectStateRemainsTappable() {
        let view = UsageBarView(
            usage: QuotaPeriod(utilization: 42, resetDate: Date(timeIntervalSince1970: 4_102_444_800)),
            isLoading: false,
            error: nil,
            statusMessage: "Tap to reconnect Claude Code",
            isStale: true,
            recoveryAction: .reconnect,
            isEnabled: true
        )

        XCTAssertTrue(view.shouldAllowTapAction)
    }

    func testNoUsageRetryStateStillShowsTapHint() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Rate limited, retrying in 120s",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .retry,
            isEnabled: true
        )

        XCTAssertEqual(view.actionHint, "(tap to retry)")
        XCTAssertTrue(view.shouldAllowTapAction)
    }

    func testNoUsageReconnectStateStillShowsTapHint() {
        let view = UsageBarView(
            usage: nil,
            isLoading: false,
            error: "Token expired",
            statusMessage: nil,
            isStale: false,
            recoveryAction: .reconnect,
            isEnabled: true
        )

        XCTAssertEqual(view.actionHint, "(tap to reconnect)")
        XCTAssertTrue(view.shouldAllowTapAction)
    }
}
