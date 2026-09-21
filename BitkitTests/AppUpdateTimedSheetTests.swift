@testable import Bitkit
import XCTest

final class AppUpdateTimedSheetTests: XCTestCase {
    private let askInterval = AppUpdateTimedSheet.ASK_INTERVAL

    private func makeUpdate(critical: Bool) -> AppUpdateInfo {
        AppUpdateInfo(buildNumber: 200, version: "1.2.3", url: "https://example.com/app", notes: nil, critical: critical)
    }

    func testShownWhenNonCriticalUpdateAndIntervalElapsed() {
        XCTAssertTrue(
            AppUpdateTimedSheet.shouldShow(
                update: makeUpdate(critical: false),
                ignoreTimestamp: 0,
                now: askInterval + 1,
                isE2E: false
            )
        )
    }

    func testHiddenWhenNoUpdateAvailable() {
        XCTAssertFalse(
            AppUpdateTimedSheet.shouldShow(
                update: nil,
                ignoreTimestamp: 0,
                now: askInterval + 1,
                isE2E: false
            )
        )
    }

    func testHiddenForCriticalUpdate() {
        // Critical updates are handled by the full-screen takeover in AppScene, not this sheet.
        XCTAssertFalse(
            AppUpdateTimedSheet.shouldShow(
                update: makeUpdate(critical: true),
                ignoreTimestamp: 0,
                now: askInterval + 1,
                isE2E: false
            )
        )
    }

    func testHiddenWithinAskInterval() {
        // Ignored one hour ago, still inside the 12h quiet window.
        XCTAssertFalse(
            AppUpdateTimedSheet.shouldShow(
                update: makeUpdate(critical: false),
                ignoreTimestamp: 0,
                now: 60 * 60,
                isE2E: false
            )
        )
    }

    func testIntervalBoundaryIsExclusive() {
        // Exactly 12h elapsed is not strictly greater than the interval, so still hidden.
        XCTAssertFalse(
            AppUpdateTimedSheet.shouldShow(
                update: makeUpdate(critical: false),
                ignoreTimestamp: 0,
                now: askInterval,
                isE2E: false
            )
        )
    }

    func testHiddenInE2EEnvironment() {
        XCTAssertFalse(
            AppUpdateTimedSheet.shouldShow(
                update: makeUpdate(critical: false),
                ignoreTimestamp: 0,
                now: askInterval + 1,
                isE2E: true
            )
        )
    }
}
