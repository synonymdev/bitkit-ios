@testable import Bitkit
import UserNotifications
import XCTest

final class ForegroundNotificationTests: XCTestCase {
    func testDueSubscriptionPaymentShowsNoBannerInTheForeground() {
        let options = AppDelegate.foregroundPresentationOptions(for: ["bitkit_action": "paykit_subscription_due"])

        XCTAssertEqual(options, [], "The in-app due sheet already shows the payment")
    }

    func testOtherNotificationsShowABannerInTheForeground() {
        XCTAssertEqual(AppDelegate.foregroundPresentationOptions(for: [:]), [.banner, .badge, .sound])
        XCTAssertEqual(
            AppDelegate.foregroundPresentationOptions(for: ["bitkit_action": "paykit_allowance"]),
            [.banner, .badge, .sound]
        )
    }

    func testLimitReachedPostsNothingWhileTheAppIsActive() {
        XCTAssertFalse(
            PaykitAllowanceNotifier.shouldPost(skipsWhileActive: true, isAppActive: true),
            "The Payment Request sheet already shows the request"
        )
    }

    func testLimitReachedIsPostedInTheBackground() {
        XCTAssertTrue(PaykitAllowanceNotifier.shouldPost(skipsWhileActive: true, isAppActive: false))
    }

    func testOutcomesTheAppDoesNotShowArePostedWhileTheAppIsActive() {
        XCTAssertTrue(
            PaykitAllowanceNotifier.shouldPost(skipsWhileActive: false, isAppActive: true),
            "Other allowance outcomes, and Limit Reached behind the PIN screen, are posted"
        )
    }
}
