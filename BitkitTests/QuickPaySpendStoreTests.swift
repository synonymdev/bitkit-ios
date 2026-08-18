@testable import Bitkit
import XCTest

final class QuickPaySpendStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sut: QuickPaySpendStore!

    override func setUp() {
        super.setUp()
        suiteName = "QuickPaySpendStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        sut = QuickPaySpendStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        sut = nil
        super.tearDown()
    }

    func testDayKeyUsesLocalCalendarDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 23, minute: 30)))

        XCTAssertEqual(QuickPaySpendStore.dayKey(date: date, timeZone: timeZone), "2026-08-15")
    }

    func testSpentUsdReturnsSpendForMatchingDayKey() {
        sut.record(amountUsd: 3.5, dayKey: "2026-08-15")

        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-15"), 3.5)
    }

    func testSpentUsdReturnsZeroForADifferentDayKey() {
        sut.record(amountUsd: 12.0, dayKey: "2026-08-14")

        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-15"), 0)
    }

    func testRecordAccumulatesOnTheSameDayAndResetsOnANewDay() {
        sut.record(amountUsd: 2.0, dayKey: "2026-08-15")
        sut.record(amountUsd: 1.5, dayKey: "2026-08-15")
        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-15"), 3.5)

        sut.record(amountUsd: 4.0, dayKey: "2026-08-16")
        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-16"), 4.0)
        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-15"), 0)
    }

    func testReserveAcceptsSpendUnderTheCapAndRejectsOverIt() {
        XCTAssertTrue(sut.tryReserve(amountUsd: 10.0, dayKey: "2026-08-15", dailyCapUsd: 25.0))
        XCTAssertTrue(sut.tryReserve(amountUsd: 10.0, dayKey: "2026-08-15", dailyCapUsd: 25.0))
        XCTAssertFalse(sut.tryReserve(amountUsd: 10.0, dayKey: "2026-08-15", dailyCapUsd: 25.0))
        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-15"), 20.0)
    }

    func testReserveAllowsSpendThatEqualsTheCap() {
        XCTAssertTrue(sut.tryReserve(amountUsd: 25.0, dayKey: "2026-08-15", dailyCapUsd: 25.0))
        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-15"), 25.0)
    }

    func testReleaseRollsBackAReservation() {
        XCTAssertTrue(sut.tryReserve(amountUsd: 5.0, dayKey: "2026-08-15", dailyCapUsd: 25.0))
        sut.release(amountUsd: 5.0, dayKey: "2026-08-15")
        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-15"), 0)
    }

    func testReleaseDoesNotChangeSpendForADifferentDay() {
        sut.record(amountUsd: 7.0, dayKey: "2026-08-16")
        sut.release(amountUsd: 7.0, dayKey: "2026-08-15")
        XCTAssertEqual(sut.spentUsd(forDayKey: "2026-08-16"), 7.0)
    }
}
