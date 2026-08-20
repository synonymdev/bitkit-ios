@testable import Bitkit
import XCTest

final class QuickPaySpendStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var currentDay = "2026-08-15"
    private var sut: QuickPaySpendStore!
    private let rates = QuickPaySpendRates(
        satsToUsdCents: { sats in Int64(sats) / 2 },
        usdToSats: { usd in UInt64(usd * 200) }
    )
    private let dustRates = QuickPaySpendRates(
        satsToUsdCents: { _ in 0 },
        usdToSats: { usd in UInt64(usd * 200) }
    )

    override func setUp() {
        super.setUp()
        suiteName = "QuickPaySpendStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        currentDay = "2026-08-15"
        sut = QuickPaySpendStore(defaults: defaults, dayKey: { [unowned self] in currentDay })
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

    func testSpentCentsTodayReturnsSpendForMatchingDay() throws {
        XCTAssertNotNil(try sut.tryReserve(amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: rates))

        XCTAssertEqual(sut.spentCentsToday(), 250)
    }

    func testSpentCentsTodayReturnsZeroForALaterDay() throws {
        XCTAssertNotNil(try sut.tryReserve(amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: rates))
        currentDay = "2026-08-16"

        XCTAssertEqual(sut.spentCentsToday(), 0)
    }

    func testSpentCentsTodayKeepsSpendOnClockRollback() throws {
        XCTAssertNotNil(try sut.tryReserve(amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: rates))
        currentDay = "2026-08-14"

        XCTAssertEqual(sut.spentCentsToday(), 250)
        XCTAssertNotNil(try sut.tryReserve(amountSats: 200, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.spentCentsToday(), 350)
        currentDay = "2026-08-15"
        XCTAssertEqual(sut.spentCentsToday(), 350)
    }

    func testTryReserveAccumulatesOnTheSameDayAndResetsOnANewDay() throws {
        XCTAssertNotNil(try sut.tryReserve(amountSats: 400, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertNotNil(try sut.tryReserve(amountSats: 300, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.spentCentsToday(), 350)

        currentDay = "2026-08-16"
        XCTAssertNotNil(try sut.tryReserve(amountSats: 800, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.spentCentsToday(), 400)
    }

    func testTryReserveReservesUnderTheCapAndRejectsOverIt() throws {
        for _ in 0 ..< 5 {
            XCTAssertNotNil(try sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        }
        XCTAssertNil(try sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.spentCentsToday(), 2500)
    }

    func testReleaseUnboundRollsBackAReservation() throws {
        let reserved = try XCTUnwrap(sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.releaseUnbound(reserved)

        XCTAssertEqual(sut.spentCentsToday(), 0)
    }

    func testReleaseUnboundOnAPriorDayDoesNotDecrementTheNewDay() throws {
        let old = try XCTUnwrap(sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        currentDay = "2026-08-16"
        XCTAssertNotNil(try sut.tryReserve(amountSats: 800, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.releaseUnbound(old)

        XCTAssertEqual(sut.spentCentsToday(), 400)
    }

    func testReleaseFreesPendingSpendByPaymentHash() throws {
        let reserved = try XCTUnwrap(sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        sut.remember(paymentHash: "abc", reservation: reserved)

        sut.release(paymentHash: "abc")

        XCTAssertEqual(sut.spentCentsToday(), 0)
        XCTAssertNil(sut.reservation(paymentHash: "abc"))
    }

    func testClearKeepsSpendAfterSuccess() throws {
        let reserved = try XCTUnwrap(sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        sut.remember(paymentHash: "abc", reservation: reserved)

        sut.clear(paymentHash: "abc")

        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertNil(sut.reservation(paymentHash: "abc"))
    }

    func testReleaseOnAPriorDayDoesNotDecrementTheNewDay() throws {
        let old = try XCTUnwrap(sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        sut.remember(paymentHash: "old", reservation: old)
        currentDay = "2026-08-16"
        XCTAssertNotNil(try sut.tryReserve(amountSats: 800, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.release(paymentHash: "old")

        XCTAssertEqual(sut.spentCentsToday(), 400)
        XCTAssertNil(sut.reservation(paymentHash: "old"))
    }

    func testAppCacheDataDecodesAndroidShapedSpendFields() throws {
        let reservation = QuickPaySpendReservation(amountCents: 500, dayKey: "2026-08-15")
        let json = """
        {
          "cachedRates": [],
          "paidOrders": {},
          "onchainAddress": "",
          "bolt11": "",
          "bolt11PaymentHash": "",
          "bip21": "",
          "balance": null,
          "backupStatuses": {},
          "deletedActivities": [],
          "pendingBoostActivities": [],
          "backgroundReceive": null,
          "addressSearchLastUsedReceiveIndexes": {},
          "addressSearchLastUsedChangeIndexes": {},
          "quickPaySpendDayKey": "2026-08-15",
          "quickPaySpentCentsToday": 500,
          "quickPayReservations": {
            "abc": { "amountCents": 500, "dayKey": "2026-08-15" }
          }
        }
        """.data(using: .utf8)!

        let cache = try JSONDecoder().decode(AppCacheData.self, from: json)
        sut.restoreFromBackup(
            dayKey: cache.quickPaySpendDayKey ?? "",
            spentCents: cache.quickPaySpentCentsToday ?? 0,
            reservations: cache.quickPayReservations ?? [:]
        )

        XCTAssertNil(cache.hasSeenQuickpayIntro)
        XCTAssertEqual(cache.quickPaySpendDayKey, "2026-08-15")
        XCTAssertEqual(cache.quickPaySpentCentsToday, 500)
        XCTAssertEqual(cache.quickPayReservations?["abc"], reservation)
        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertEqual(sut.reservation(paymentHash: "abc"), reservation)
    }

    func testTryReserveReturnsNilWhenAmountExceedsThresholdSats() throws {
        let tightRates = QuickPaySpendRates(
            satsToUsdCents: { sats in Int64(sats) / 2 },
            usdToSats: { _ in 100 }
        )

        XCTAssertNil(try sut.tryReserve(amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: tightRates))
        XCTAssertEqual(sut.spentCentsToday(), 0)
    }

    func testBackupSnapshotRoundTripsSpendAndReservations() throws {
        let reserved = try XCTUnwrap(sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        sut.remember(paymentHash: "abc", reservation: reserved)

        let snapshot = sut.backupSnapshot()
        let restored = QuickPaySpendStore(defaults: defaults, dayKey: { [unowned self] in currentDay })
        restored.restoreFromBackup(
            dayKey: snapshot.dayKey,
            spentCents: snapshot.spentCents,
            reservations: snapshot.reservations
        )

        XCTAssertEqual(restored.spentCentsToday(), 500)
        XCTAssertEqual(restored.reservation(paymentHash: "abc"), reserved)
    }

    func testCanApplyIsTrueUnderThresholdAndCap() {
        XCTAssertTrue(
            sut.canApply(amountSats: 500, enabled: true, thresholdUsd: 5, multiplier: 5, rates: rates)
        )
    }

    func testZeroCentConversionAtFullCapDoesNotQuickPay() throws {
        for _ in 0 ..< 5 {
            XCTAssertNotNil(try sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        }

        XCTAssertFalse(
            sut.canApply(amountSats: 7, enabled: true, thresholdUsd: 5, multiplier: 5, rates: dustRates)
        )
        XCTAssertNil(try sut.tryReserve(amountSats: 7, thresholdUsd: 5, multiplier: 5, rates: dustRates))
    }

    func testZeroCentConversionReservesOneCent() throws {
        let reserved = try XCTUnwrap(sut.tryReserve(amountSats: 7, thresholdUsd: 5, multiplier: 5, rates: dustRates))

        XCTAssertEqual(reserved.amountCents, 1)
        XCTAssertEqual(sut.spentCentsToday(), 1)
    }

    func testCanApplyIsFalseWhenDailyCapWouldBeExceeded() throws {
        XCTAssertNotNil(try sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 1, rates: rates))

        XCTAssertFalse(
            sut.canApply(amountSats: 1000, enabled: true, thresholdUsd: 5, multiplier: 1, rates: rates)
        )
    }

    func testCanApplyIsFalseWhenDisabled() {
        XCTAssertFalse(
            sut.canApply(amountSats: 500, enabled: false, thresholdUsd: 5, multiplier: 5, rates: rates)
        )
    }

    func testTryReserveFailsWithConversionErrorWhenRatesAreUnavailable() {
        let missingRates = QuickPaySpendRates(
            satsToUsdCents: { _ in nil },
            usdToSats: { usd in UInt64(usd * 200) }
        )

        XCTAssertThrowsError(
            try sut.tryReserve(amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: missingRates)
        ) { error in
            XCTAssertTrue(error is QuickPayConversionError)
        }
    }

    func testReservationSurvivesANewStoreInstance() throws {
        let reserved = try XCTUnwrap(sut.tryReserve(amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        sut.remember(paymentHash: "abc", reservation: reserved)

        let reloaded = QuickPaySpendStore(defaults: defaults, dayKey: { [unowned self] in currentDay })
        reloaded.release(paymentHash: "abc")

        XCTAssertEqual(reloaded.spentCentsToday(), 0)
    }
}
