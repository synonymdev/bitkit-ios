@testable import Bitkit
import XCTest

final class DemoClockTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DemoClockTests-\(UUID().uuidString)"
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

        XCTAssertEqual(DemoClock.offsetDays(defaults: defaults, isAvailable: true), 0)
        XCTAssertEqual(DemoClock.subscriptionDate(from: date, defaults: defaults, isAvailable: true), date)
    }

    func testOffsetMovesSubscriptionDateByWholeDays() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(31, forKey: DemoClock.offsetDaysKey)

        XCTAssertEqual(
            DemoClock.subscriptionDate(from: date, defaults: defaults, isAvailable: true),
            date.addingTimeInterval(31 * 24 * 60 * 60)
        )
    }

    func testOffsetIsIgnoredWhenUnavailable() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(31, forKey: DemoClock.offsetDaysKey)

        XCTAssertEqual(DemoClock.offsetDays(defaults: defaults, isAvailable: false), 0)
        XCTAssertEqual(DemoClock.subscriptionDate(from: date, defaults: defaults, isAvailable: false), date)
    }

    func testOffsetIsClampedToSupportedRange() {
        defaults.set(-5, forKey: DemoClock.offsetDaysKey)
        XCTAssertEqual(DemoClock.offsetDays(defaults: defaults, isAvailable: true), 0)

        defaults.set(10000, forKey: DemoClock.offsetDaysKey)
        XCTAssertEqual(DemoClock.offsetDays(defaults: defaults, isAvailable: true), DemoClock.offsetDaysRange.upperBound)
    }
}
