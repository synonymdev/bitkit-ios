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

    func testReserveBoundAccumulatesAndRejectsOverCap() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "a", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "b", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        for i in 2 ..< 5 {
            XCTAssertNotNil(try sut.reserveBound(paymentHash: "h\(i)", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        }
        XCTAssertNil(try sut.reserveBound(paymentHash: "over", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.spentCentsToday(), 2500)
    }

    func testReserveBoundDoesNotDoubleSpendTheSameHash() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "abc", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertNil(try sut.reserveBound(paymentHash: "abc", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.spentCentsToday(), 500)
    }

    func testSpentCentsTodayReturnsZeroForALaterDay() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "abc", amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: rates))
        currentDay = "2026-08-16"

        XCTAssertEqual(sut.spentCentsToday(), 0)
    }

    func testSpentCentsTodayKeepsSpendOnClockRollback() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "a", amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: rates))
        currentDay = "2026-08-14"

        XCTAssertEqual(sut.spentCentsToday(), 250)
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "b", amountSats: 200, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.spentCentsToday(), 350)
        currentDay = "2026-08-15"
        XCTAssertEqual(sut.spentCentsToday(), 350)
    }

    func testSignalCompletionFailureReleasesSpend() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "abc", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        XCTAssertEqual(sut.signalCompletion(paymentId: nil, paymentHash: "abc", success: false), .settledFailure)
        XCTAssertEqual(sut.spentCentsToday(), 0)
        XCTAssertNil(sut.record(matching: "abc"))
    }

    func testSignalCompletionSuccessKeepsSpend() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "abc", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        XCTAssertEqual(sut.signalCompletion(paymentId: nil, paymentHash: "abc", success: true), .settledSuccess)
        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertNil(sut.record(matching: "abc"))
        XCTAssertTrue(QuickPayCompletionOutcome.settledSuccess.wasQuickPay)
        XCTAssertFalse(QuickPayCompletionOutcome.none.wasQuickPay)
    }

    func testSignalCompletionMatchesPaymentIdAlias() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "inv", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        sut.markSubmitted(invoicePaymentHash: "inv", paymentId: "pid")

        XCTAssertEqual(sut.signalCompletion(paymentId: "pid", paymentHash: "other", success: false), .settledFailure)
        XCTAssertEqual(sut.spentCentsToday(), 0)
    }

    func testMarkSubmittedAfterCompletionIsNoOp() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "inv", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.signalCompletion(paymentId: nil, paymentHash: "inv", success: true), .settledSuccess)

        sut.markSubmitted(invoicePaymentHash: "inv", paymentId: "pid")

        XCTAssertNil(sut.record(matching: "inv"))
        XCTAssertEqual(sut.spentCentsToday(), 500)
    }

    func testDuplicateSignalCompletionDoesNotDecrementTwice() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "abc", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        XCTAssertEqual(sut.signalCompletion(paymentId: nil, paymentHash: "abc", success: false), .settledFailure)
        XCTAssertEqual(sut.signalCompletion(paymentId: nil, paymentHash: "abc", success: false), .none)
        XCTAssertEqual(sut.spentCentsToday(), 0)
    }

    func testReleaseOnAPriorDayDoesNotDecrementTheNewDay() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "old", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        currentDay = "2026-08-16"
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "new", amountSats: 800, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.releaseBound(paymentHash: "old")

        XCTAssertEqual(sut.spentCentsToday(), 400)
        XCTAssertNil(sut.record(matching: "old"))
    }

    func testReconcileFailedReleasesRecoveredRecord() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "inv", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.reconcile(
            rows: [QuickPayReconcileRow(paymentId: "pid", invoicePaymentHash: "inv", isOutboundBolt11: true, status: .failed)],
            liveSubmittingHashes: []
        )

        XCTAssertEqual(sut.spentCentsToday(), 0)
        XCTAssertNil(sut.record(matching: "inv"))
    }

    func testReconcileSucceededClearsAndKeepsSpend() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "inv", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.reconcile(
            rows: [QuickPayReconcileRow(paymentId: "pid", invoicePaymentHash: "inv", isOutboundBolt11: true, status: .succeeded)],
            liveSubmittingHashes: []
        )

        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertNil(sut.record(matching: "inv"))
    }

    func testReconcileAbsentOrPendingRetains() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "inv", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.reconcile(rows: [], liveSubmittingHashes: [])
        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertNotNil(sut.record(matching: "inv"))

        sut.reconcile(
            rows: [QuickPayReconcileRow(paymentId: "pid", invoicePaymentHash: "inv", isOutboundBolt11: true, status: .pending)],
            liveSubmittingHashes: []
        )
        XCTAssertNotNil(sut.record(matching: "inv"))
    }

    func testReconcileNilLeavesLedgerUnchanged() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "inv", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.reconcile(rows: nil, liveSubmittingHashes: [])

        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertNotNil(sut.record(matching: "inv"))
    }

    func testReconcileSkipsLiveSubmitting() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "inv", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        sut.reconcile(
            rows: [QuickPayReconcileRow(paymentId: "pid", invoicePaymentHash: "inv", isOutboundBolt11: true, status: .failed)],
            liveSubmittingHashes: ["inv"]
        )

        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertNotNil(sut.record(matching: "inv"))
    }

    func testAppCacheDataDecodesLegacySpendFields() throws {
        let json = """
        {
          "hasSeenContactsIntro": false,
          "hasSeenProfileIntro": false,
          "hasSeenNotificationsIntro": false,
          "hasSeenQuickpayIntro": false,
          "hasSeenShopIntro": false,
          "hasSeenTransferIntro": false,
          "hasSeenTransferToSpendingIntro": false,
          "hasSeenTransferToSavingsIntro": false,
          "hasSeenWidgetsIntro": false,
          "appUpdateIgnoreTimestamp": 0,
          "backupIgnoreTimestamp": 0,
          "highBalanceIgnoreCount": 0,
          "highBalanceIgnoreTimestamp": 0,
          "dismissedSuggestions": [],
          "lastUsedTags": [],
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

        XCTAssertEqual(sut.spentCentsToday(), 500)
        XCTAssertNotNil(sut.record(matching: "abc"))
    }

    func testCanApplyIsTrueUnderThresholdAndCap() {
        XCTAssertTrue(
            sut.canApply(amountSats: 500, enabled: true, thresholdUsd: 5, multiplier: 5, rates: rates)
        )
    }

    func testZeroCentConversionAtFullCapDoesNotQuickPay() throws {
        for i in 0 ..< 5 {
            XCTAssertNotNil(try sut.reserveBound(paymentHash: "h\(i)", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))
        }

        XCTAssertFalse(
            sut.canApply(amountSats: 7, enabled: true, thresholdUsd: 5, multiplier: 5, rates: dustRates)
        )
        XCTAssertNil(try sut.reserveBound(paymentHash: "dust", amountSats: 7, thresholdUsd: 5, multiplier: 5, rates: dustRates))
    }

    func testZeroCentConversionReservesOneCent() throws {
        let reserved = try XCTUnwrap(sut.reserveBound(paymentHash: "dust", amountSats: 7, thresholdUsd: 5, multiplier: 5, rates: dustRates))

        XCTAssertEqual(reserved.amountCents, 1)
        XCTAssertEqual(sut.spentCentsToday(), 1)
    }

    func testCanApplyIsFalseWhenDailyCapWouldBeExceeded() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "a", amountSats: 1000, thresholdUsd: 5, multiplier: 1, rates: rates))

        XCTAssertFalse(
            sut.canApply(amountSats: 1000, enabled: true, thresholdUsd: 5, multiplier: 1, rates: rates)
        )
    }

    func testCanApplyIsFalseWhenDisabled() {
        XCTAssertFalse(
            sut.canApply(amountSats: 500, enabled: false, thresholdUsd: 5, multiplier: 5, rates: rates)
        )
    }

    func testReserveBoundFailsWithConversionErrorWhenRatesAreUnavailable() {
        let missingRates = QuickPaySpendRates(
            satsToUsdCents: { _ in nil },
            usdToSats: { usd in UInt64(usd * 200) }
        )

        XCTAssertThrowsError(
            try sut.reserveBound(paymentHash: "abc", amountSats: 500, thresholdUsd: 5, multiplier: 5, rates: missingRates)
        ) { error in
            XCTAssertTrue(error is QuickPayConversionError)
        }
    }

    func testRecordSurvivesANewStoreInstance() throws {
        XCTAssertNotNil(try sut.reserveBound(paymentHash: "abc", amountSats: 1000, thresholdUsd: 5, multiplier: 5, rates: rates))

        let reloaded = QuickPaySpendStore(defaults: defaults, dayKey: { [unowned self] in currentDay })
        XCTAssertEqual(reloaded.signalCompletion(paymentId: nil, paymentHash: "abc", success: false), .settledFailure)

        XCTAssertEqual(reloaded.spentCentsToday(), 0)
    }
}
