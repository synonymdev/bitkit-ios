@testable import Bitkit
import XCTest

final class SubscriptionClockTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SubscriptionClockTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testOffsetIsOffByDefault() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(SubscriptionClock.offsetDays(defaults: defaults, isAvailable: true), 0)
        XCTAssertEqual(SubscriptionClock.subscriptionDate(from: date, defaults: defaults, isAvailable: true), date)
    }

    func testOffsetMovesSubscriptionDateByWholeDays() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(31, forKey: SubscriptionClock.offsetDaysKey)

        XCTAssertEqual(
            SubscriptionClock.subscriptionDate(from: date, defaults: defaults, isAvailable: true),
            date.addingTimeInterval(31 * 24 * 60 * 60)
        )
    }

    func testOffsetIsIgnoredWhenUnavailable() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(31, forKey: SubscriptionClock.offsetDaysKey)

        XCTAssertEqual(SubscriptionClock.offsetDays(defaults: defaults, isAvailable: false), 0)
        XCTAssertEqual(SubscriptionClock.subscriptionDate(from: date, defaults: defaults, isAvailable: false), date)
    }

    func testOffsetIsClampedToSupportedRange() {
        defaults.set(-5, forKey: SubscriptionClock.offsetDaysKey)
        XCTAssertEqual(SubscriptionClock.offsetDays(defaults: defaults, isAvailable: true), 0)

        defaults.set(10000, forKey: SubscriptionClock.offsetDaysKey)
        XCTAssertEqual(SubscriptionClock.offsetDays(defaults: defaults, isAvailable: true), SubscriptionClock.offsetDaysRange.upperBound)
    }
}
