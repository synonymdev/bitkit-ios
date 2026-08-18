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

    func testSpentSatsReturnsSpendForMatchingDayKey() {
        sut.record(amountSats: 3500, dayKey: "2026-08-15")

        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 3500)
    }

    func testSpentSatsReturnsZeroForALaterDayKey() {
        sut.record(amountSats: 12000, dayKey: "2026-08-14")

        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 0)
    }

    func testSpentSatsKeepsSpendOnClockRollback() {
        sut.record(amountSats: 12000, dayKey: "2026-08-15")

        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-14"), 12000)
        XCTAssertTrue(sut.tryReserve(amountSats: 1000, dayKey: "2026-08-14", dailyCapSats: 20000))
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-14"), 13000)
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 13000)
    }

    func testRecordAccumulatesOnTheSameDayAndResetsOnANewDay() {
        sut.record(amountSats: 2000, dayKey: "2026-08-15")
        sut.record(amountSats: 1500, dayKey: "2026-08-15")
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 3500)

        sut.record(amountSats: 4000, dayKey: "2026-08-16")
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-16"), 4000)
        // An earlier key is treated as a clock rollback, so stored spend is kept.
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 4000)
    }

    func testReserveAcceptsSpendUnderTheCapAndRejectsOverIt() {
        XCTAssertTrue(sut.tryReserve(amountSats: 10000, dayKey: "2026-08-15", dailyCapSats: 25000))
        XCTAssertTrue(sut.tryReserve(amountSats: 10000, dayKey: "2026-08-15", dailyCapSats: 25000))
        XCTAssertFalse(sut.tryReserve(amountSats: 10000, dayKey: "2026-08-15", dailyCapSats: 25000))
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 20000)
    }

    func testReserveAllowsSpendThatEqualsTheCap() {
        XCTAssertTrue(sut.tryReserve(amountSats: 25000, dayKey: "2026-08-15", dailyCapSats: 25000))
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 25000)
    }

    func testReleaseRollsBackAReservation() {
        XCTAssertTrue(sut.tryReserve(amountSats: 5000, dayKey: "2026-08-15", dailyCapSats: 25000))
        sut.release(amountSats: 5000, dayKey: "2026-08-15")
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 0)
    }

    func testReleaseDoesNotChangeSpendForALaterDay() {
        sut.record(amountSats: 7000, dayKey: "2026-08-15")
        sut.release(amountSats: 7000, dayKey: "2026-08-16")
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 7000)
    }

    func testReleaseSubtractsOnClockRollback() {
        sut.record(amountSats: 7000, dayKey: "2026-08-15")
        sut.release(amountSats: 1000, dayKey: "2026-08-14")
        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 6000)
    }

    func testReleasePendingRollsBackATrackedReservation() {
        XCTAssertTrue(sut.tryReserve(amountSats: 5000, dayKey: "2026-08-15", dailyCapSats: 25000))
        sut.trackPending(paymentHash: "abc", amountSats: 5000, dayKey: "2026-08-15")

        sut.releasePending(paymentHash: "abc")

        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 0)
        XCTAssertTrue(sut.tryReserve(amountSats: 25000, dayKey: "2026-08-15", dailyCapSats: 25000))
    }

    func testReleasePendingSubtractsOnClockRollback() {
        XCTAssertTrue(sut.tryReserve(amountSats: 5000, dayKey: "2026-08-15", dailyCapSats: 25000))
        sut.trackPending(paymentHash: "abc", amountSats: 5000, dayKey: "2026-08-14")

        sut.releasePending(paymentHash: "abc")

        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 0)
    }

    func testForgetPendingKeepsTheReservation() {
        XCTAssertTrue(sut.tryReserve(amountSats: 5000, dayKey: "2026-08-15", dailyCapSats: 25000))
        sut.trackPending(paymentHash: "abc", amountSats: 5000, dayKey: "2026-08-15")

        sut.forgetPending(paymentHash: "abc")
        sut.releasePending(paymentHash: "abc")

        XCTAssertEqual(sut.spentSats(forDayKey: "2026-08-15"), 5000)
    }

    func testPendingReservationSurvivesANewStoreInstance() {
        XCTAssertTrue(sut.tryReserve(amountSats: 5000, dayKey: "2026-08-15", dailyCapSats: 25000))
        sut.trackPending(paymentHash: "abc", amountSats: 5000, dayKey: "2026-08-15")

        let reloaded = QuickPaySpendStore(defaults: defaults)
        reloaded.releasePending(paymentHash: "abc")

        XCTAssertEqual(reloaded.spentSats(forDayKey: "2026-08-15"), 0)
    }
}
