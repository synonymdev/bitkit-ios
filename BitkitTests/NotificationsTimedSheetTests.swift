@testable import Bitkit
import XCTest

final class NotificationsTimedSheetTests: XCTestCase {
    func testShownWhenSubscriptionActiveAndNotificationsOff() {
        XCTAssertTrue(NotificationsTimedSheet.shouldShow(notificationsEnabled: false, hasSeenIntro: false, hasActiveSubscription: true))
    }

    func testHiddenWithoutActiveSubscription() {
        XCTAssertFalse(NotificationsTimedSheet.shouldShow(notificationsEnabled: false, hasSeenIntro: false, hasActiveSubscription: false))
    }

    func testHiddenWhenNotificationsAlreadyOn() {
        XCTAssertFalse(NotificationsTimedSheet.shouldShow(notificationsEnabled: true, hasSeenIntro: false, hasActiveSubscription: true))
    }

    func testHiddenAfterIntroSeen() {
        XCTAssertFalse(NotificationsTimedSheet.shouldShow(notificationsEnabled: false, hasSeenIntro: true, hasActiveSubscription: true))
    }
}
