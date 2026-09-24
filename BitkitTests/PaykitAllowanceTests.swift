@testable import Bitkit
import Foundation
import LDKNode
import Paykit
import XCTest

final class PaykitAllowanceTests: XCTestCase {
    private typealias Fixtures = PaykitAllowanceFixtures

    // MARK: Terms and records

    func testTermsCarryPerPaymentRangeAnchoredUtcMonthAndAllowlist() throws {
        let monthAnchor = PaykitAllowanceTime.monthStart(containing: Fixtures.now)
        let allowlist = [Fixtures.lightningIdentifier, Fixtures.onchainIdentifier]

        let terms = try Fixtures.limits.terms(monthAnchor: monthAnchor, allowedPaymentEndpointIdentifiers: allowlist)

        XCTAssertEqual(terms.asset(), PaykitIssuerInterop.bitcoinAsset)
        let perPayment = try XCTUnwrap(terms.perPaymentAmount())
        XCTAssertEqual(perPayment.minimum(), "0")
        XCTAssertEqual(perPayment.maximum(), "0.00005")
        XCTAssertEqual(terms.periodLimits().count, 1)
        let monthly = try XCTUnwrap(terms.periodLimits().first)
        XCTAssertEqual(monthly.amountLimit(), "0.0005")
        XCTAssertNil(monthly.paymentCountLimit())
        XCTAssertEqual(monthly.period().kind(), "anchored")
        XCTAssertEqual(monthly.period().every(), 1)
        XCTAssertEqual(monthly.period().unit(), "month")
        XCTAssertTrue(PaykitAllowance.isMonthly(monthly.period()))
        XCTAssertEqual(monthly.period().anchor(), "2026-09-01T00:00:00.000Z")
        XCTAssertEqual(monthly.period().anchor().flatMap(PaykitAllowanceTime.parse), Fixtures.septemberAnchor)
        XCTAssertNil(terms.lifetimeAmountLimit())
        XCTAssertNil(terms.activeFrom())
        XCTAssertNil(terms.expiresAt())
        XCTAssertEqual(terms.allowedPaymentEndpointIdentifiers(), allowlist)
    }

    func testRecordReadsBackSatsAnchorRoleAndAllowlist() throws {
        let allowlist = [Fixtures.lightningIdentifier, Fixtures.onchainIdentifier]
        let terms = try Fixtures.limits.terms(monthAnchor: Fixtures.septemberAnchor, allowedPaymentEndpointIdentifiers: allowlist)
        let record = Fixtures.record(state: .proposed, terms: terms, proposedByMe: true)

        let allowance = try XCTUnwrap(PaykitAllowance(record: record))

        XCTAssertEqual(allowance.counterparty, Fixtures.counterpartyKey)
        XCTAssertEqual(allowance.counterpartyReceiverPath, PaykitReceiverPath.wallet)
        XCTAssertEqual(allowance.allowanceId, Fixtures.walletAllowanceId)
        XCTAssertEqual(allowance.role, .allower)
        XCTAssertTrue(allowance.isAllower)
        XCTAssertTrue(allowance.isProposedByMe)
        XCTAssertEqual(allowance.lifecycleState, .proposed)
        XCTAssertEqual(allowance.perPaymentMaxSats, 5000)
        XCTAssertEqual(allowance.monthlyLimitSats, 50000)
        XCTAssertEqual(allowance.monthlyAnchor, Fixtures.septemberAnchor)
        XCTAssertNil(allowance.activeFrom)
        XCTAssertNil(allowance.expiresAt)
        XCTAssertEqual(allowance.allowedPaymentEndpointIdentifiers, allowlist)
        XCTAssertEqual(allowance.lastEventAt, Fixtures.utc("2026-09-02T10:00:00Z"))

        let receivedRecord = Fixtures.record(localRole: .allowee, state: .proposed, terms: terms, proposedByMe: false)
        let received = try XCTUnwrap(PaykitAllowance(record: receivedRecord))
        XCTAssertEqual(received.role, .allowee)
        XCTAssertFalse(received.isAllower)
        XCTAssertFalse(received.isProposedByMe)
        XCTAssertTrue(received.isAnswerable)
    }

    func testRecordWithoutUsableRoleOrTermsIsSkipped() throws {
        let terms = try Fixtures.standardTerms()

        XCTAssertNil(PaykitAllowance(record: Fixtures.record(localRole: nil, terms: terms)))
        XCTAssertNil(PaykitAllowance(record: Fixtures.record(localRole: .unknown, terms: terms)))
        XCTAssertNil(PaykitAllowance(record: Fixtures.record(terms: nil)))
    }

    func testStatusMapsEveryLifecycleState() throws {
        func status(
            _ state: Paykit.AllowanceLifecycleState,
            proposedByMe: Bool = true,
            terms: Paykit.AllowanceTerms? = nil,
            at date: Date = PaykitAllowanceFixtures.now
        ) throws -> PaykitAllowance.Status {
            let resolvedTerms = try terms ?? Fixtures.standardTerms()
            let record = Fixtures.record(state: state, terms: resolvedTerms, proposedByMe: proposedByMe)
            return try XCTUnwrap(PaykitAllowance(record: record)).status(at: date)
        }

        XCTAssertEqual(try status(.proposed, proposedByMe: true), .awaitingAnswer)
        XCTAssertEqual(try status(.proposed, proposedByMe: false), .awaitingMyAnswer)
        XCTAssertEqual(try status(.accepted), .active)
        XCTAssertEqual(try status(.rejected), .declined)
        XCTAssertEqual(try status(.ended), .ended)
        XCTAssertEqual(try status(.conflicted), .conflicted)
        XCTAssertEqual(try status(.unknown), .conflicted)

        let expiry = Fixtures.utc("2026-09-20T00:00:00Z")
        let expiring = try Fixtures.customTerms(expiresAt: expiry)
        XCTAssertEqual(try status(.accepted, terms: expiring, at: expiry.addingTimeInterval(-1)), .active)
        XCTAssertEqual(try status(.accepted, terms: expiring, at: expiry), .expired)
        XCTAssertEqual(try status(.accepted, terms: expiring, at: Fixtures.now), .expired)

        let start = Fixtures.utc("2026-10-01T00:00:00Z")
        let scheduled = try Fixtures.customTerms(activeFrom: start)
        XCTAssertEqual(try status(.accepted, terms: scheduled, at: Fixtures.now), .notYetActive)
        XCTAssertEqual(try status(.accepted, terms: scheduled, at: start), .active)
    }

    func testSatsFromBitcoinAmountReadsTheZeroMinimum() {
        XCTAssertEqual(PaykitAllowance.sats(fromBitcoinAmount: "0"), 0)
        XCTAssertEqual(PaykitAllowance.sats(fromBitcoinAmount: "0.00000000"), 0)
        XCTAssertEqual(PaykitAllowance.sats(fromBitcoinAmount: "0.00005"), 5000)
        XCTAssertEqual(PaykitAllowance.sats(fromBitcoinAmount: "0.0005"), 50000)
        XCTAssertNil(PaykitAllowance.sats(fromBitcoinAmount: "abc"))
    }

    // MARK: Monthly window

    func testMonthStartUsesTheUtcCalendarMonth() {
        XCTAssertEqual(PaykitAllowanceTime.monthStart(containing: Fixtures.now), Fixtures.septemberAnchor)
        XCTAssertEqual(PaykitAllowanceTime.monthStart(containing: Fixtures.utc("2026-10-01T01:00:00+02:00")), Fixtures.septemberAnchor)
        XCTAssertEqual(
            PaykitAllowanceTime.monthStart(containing: Fixtures.utc("2026-09-30T23:30:00-02:00")),
            Fixtures.utc("2026-10-01T00:00:00Z")
        )
    }

    func testMonthlyWindowFromFirstOfMonthAnchor() {
        let anchor = Fixtures.septemberAnchor
        let cases: [(date: String, start: String, end: String)] = [
            ("2026-09-01T00:00:00Z", "2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z"),
            ("2026-09-24T12:00:00Z", "2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z"),
            ("2026-09-30T23:59:59Z", "2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z"),
            ("2026-10-01T00:00:00Z", "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z"),
            ("2026-12-31T23:59:59Z", "2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z"),
            ("2027-02-10T08:00:00Z", "2027-02-01T00:00:00Z", "2027-03-01T00:00:00Z"),
            ("2026-08-31T23:59:59Z", "2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z"),
            ("2026-07-15T12:00:00Z", "2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z"),
        ]

        for testCase in cases {
            let window = PaykitAllowanceTime.monthlyWindow(anchor: anchor, containing: Fixtures.utc(testCase.date))
            XCTAssertEqual(window.start, Fixtures.utc(testCase.start), "start for \(testCase.date)")
            XCTAssertEqual(window.end, Fixtures.utc(testCase.end), "end for \(testCase.date)")
        }
    }

    func testMonthlyWindowClampsJanuaryThirtyFirstAnchorInFebruary() {
        let anchor = Fixtures.utc("2026-01-31T12:30:00Z")

        let midFebruary = PaykitAllowanceTime.monthlyWindow(anchor: anchor, containing: Fixtures.utc("2026-02-15T00:00:00Z"))
        XCTAssertEqual(midFebruary.start, anchor)
        XCTAssertEqual(midFebruary.end, Fixtures.utc("2026-02-28T12:30:00Z"))

        let lateFebruary = PaykitAllowanceTime.monthlyWindow(anchor: anchor, containing: Fixtures.utc("2026-02-28T12:30:00Z"))
        XCTAssertEqual(lateFebruary.start, Fixtures.utc("2026-02-28T12:30:00Z"))
    }

    /// Vectors from paykit-lib `test_anchored_months_clamp_from_original_anchor`: every boundary is counted from the
    /// original anchor, so the window after a clamped February still ends on March 31.
    func testMonthlyWindowAfterClampedFebruaryMatchesPaykitAnchoredArithmetic() {
        let anchor = Fixtures.utc("2026-01-31T12:30:00Z")
        let vectors: [(date: String, start: String, end: String)] = [
            ("2026-02-28T12:30:00Z", "2026-02-28T12:30:00Z", "2026-03-31T12:30:00Z"),
            ("2026-03-30T12:30:00Z", "2026-02-28T12:30:00Z", "2026-03-31T12:30:00Z"),
            ("2025-12-01T00:00:00Z", "2025-11-30T12:30:00Z", "2025-12-31T12:30:00Z"),
        ]
        let marchAnchor = Fixtures.utc("2026-03-31T00:00:00Z")
        let beforeMarchAnchor = PaykitAllowanceTime.monthlyWindow(anchor: marchAnchor, containing: Fixtures.utc("2026-01-15T00:00:00Z"))
        let allowance = Fixtures.allowance(monthlyAnchor: anchor)
        let lateMarchAttempt = PaykitAllowanceCapacity.Attempt(
            allowanceId: allowance.allowanceId,
            amountSats: 50000,
            admittedAt: Fixtures.utc("2026-03-29T09:00:00Z"),
            isLive: true
        )

        XCTExpectFailure(
            "PaykitAllowanceTime.monthlyWindow steps one month from an already clamped date instead of counting from the original anchor"
        ) {
            for vector in vectors {
                let window = PaykitAllowanceTime.monthlyWindow(anchor: anchor, containing: Fixtures.utc(vector.date))
                XCTAssertEqual(window.start, Fixtures.utc(vector.start), "start for \(vector.date)")
                XCTAssertEqual(window.end, Fixtures.utc(vector.end), "end for \(vector.date)")
            }
            XCTAssertEqual(beforeMarchAnchor.start, Fixtures.utc("2025-12-31T00:00:00Z"), "start before a March 31 anchor")
            XCTAssertEqual(beforeMarchAnchor.end, Fixtures.utc("2026-01-31T00:00:00Z"), "end before a March 31 anchor")
            XCTAssertFalse(
                PaykitAllowanceCapacity.fits(
                    amountSats: 1000,
                    allowance: allowance,
                    attempts: [lateMarchAttempt],
                    now: Fixtures.utc("2026-03-30T12:30:00Z")
                ),
                "A March 29 attempt at the cap must count on March 30"
            )
        }
    }

    // MARK: Capacity

    func testCapacityFitsUnderTheCap() {
        let attempts = [Fixtures.capacityAttempt(sats: 20000, at: "2026-09-05T10:00:00Z")]

        XCTAssertEqual(Fixtures.usedSats(attempts), 20000)
        XCTAssertTrue(PaykitAllowanceCapacity.fits(amountSats: 5000, allowance: Fixtures.allowance(), attempts: attempts, now: Fixtures.now))
    }

    func testCapacityFitsExactlyAtTheCap() {
        let attempts = [
            Fixtures.capacityAttempt(sats: 20000, at: "2026-09-05T10:00:00Z"),
            Fixtures.capacityAttempt(sats: 25000, at: "2026-09-12T10:00:00Z"),
        ]

        XCTAssertTrue(PaykitAllowanceCapacity.fits(amountSats: 5000, allowance: Fixtures.allowance(), attempts: attempts, now: Fixtures.now))
    }

    func testCapacityRejectsOverTheMonthlyCap() {
        let attempts = [
            Fixtures.capacityAttempt(sats: 20000, at: "2026-09-05T10:00:00Z"),
            Fixtures.capacityAttempt(sats: 25000, at: "2026-09-12T10:00:00Z"),
        ]

        XCTAssertFalse(PaykitAllowanceCapacity.fits(amountSats: 5001, allowance: Fixtures.allowance(), attempts: attempts, now: Fixtures.now))
    }

    func testCapacityRejectsOverThePerPaymentMaximum() {
        let allowance = Fixtures.allowance()

        XCTAssertTrue(PaykitAllowanceCapacity.fits(amountSats: 5000, allowance: allowance, attempts: [], now: Fixtures.now))
        XCTAssertFalse(PaykitAllowanceCapacity.fits(amountSats: 5001, allowance: allowance, attempts: [], now: Fixtures.now))
    }

    func testCapacityIgnoresFailedAttempts() {
        let attempts = [
            Fixtures.capacityAttempt(sats: 45000, at: "2026-09-05T10:00:00Z", isLive: false),
            Fixtures.capacityAttempt(sats: 10000, at: "2026-09-12T10:00:00Z"),
        ]

        XCTAssertEqual(Fixtures.usedSats(attempts), 10000)
        XCTAssertTrue(PaykitAllowanceCapacity.fits(amountSats: 5000, allowance: Fixtures.allowance(), attempts: attempts, now: Fixtures.now))
    }

    func testCapacityIgnoresPreviousMonthAndOtherAllowanceAttempts() {
        let attempts = [
            Fixtures.capacityAttempt(sats: 50000, at: "2026-08-31T23:59:59Z"),
            Fixtures.capacityAttempt(allowanceId: Fixtures.serverAllowanceId, sats: 50000, at: "2026-09-10T10:00:00Z"),
            Fixtures.capacityAttempt(sats: 1000, at: "2026-09-01T00:00:00Z"),
        ]

        XCTAssertEqual(Fixtures.usedSats(attempts), 1000)
        XCTAssertTrue(PaykitAllowanceCapacity.fits(amountSats: 5000, allowance: Fixtures.allowance(), attempts: attempts, now: Fixtures.now))
    }

    func testCapacityWithoutMonthlyLimitChecksOnlyThePerPaymentMaximum() {
        let allowance = Fixtures.allowance(monthlyLimitSats: nil)
        let attempts = [Fixtures.capacityAttempt(sats: 1_000_000, at: "2026-09-05T10:00:00Z")]

        XCTAssertTrue(PaykitAllowanceCapacity.fits(amountSats: 5000, allowance: allowance, attempts: attempts, now: Fixtures.now))
    }

    func testAttemptsFromHistoryKeepAutomaticAllowanceAttempts() throws {
        let history = try Paykit.AllowanceAccountingHistory(
            associations: [],
            occurrences: [
                Fixtures.occurrence(requestId: "req-1", attempts: [
                    Fixtures.attemptRecord(id: "failed", amount: "0.0001", admittedAt: "2026-09-02T10:00:00Z", status: .failed),
                    Fixtures.attemptRecord(id: "paid", amount: "0.0001", admittedAt: "2026-09-03T10:00:00Z", status: .succeeded),
                ]),
                Fixtures.occurrence(requestId: "req-2", attempts: [
                    Fixtures.attemptRecord(id: "manual", mode: .manual, allowanceId: nil, admittedAt: "2026-09-04T10:00:00Z", status: .succeeded),
                    Fixtures.attemptRecord(id: "unattributed", allowanceId: nil, admittedAt: "2026-09-04T11:00:00Z", status: .succeeded),
                    Fixtures.attemptRecord(id: "open", amount: "0.00002", admittedAt: "2026-09-05T10:00:00Z", status: .submitted),
                ]),
            ],
            watermarks: []
        )

        let attempts = PaykitAllowanceCapacity.attempts(from: history)

        XCTAssertEqual(attempts, [
            PaykitAllowanceCapacity.Attempt(
                allowanceId: Fixtures.walletAllowanceId,
                amountSats: 10000,
                admittedAt: Fixtures.utc("2026-09-02T10:00:00Z"),
                isLive: false
            ),
            PaykitAllowanceCapacity.Attempt(
                allowanceId: Fixtures.walletAllowanceId,
                amountSats: 10000,
                admittedAt: Fixtures.utc("2026-09-03T10:00:00Z"),
                isLive: true
            ),
            PaykitAllowanceCapacity.Attempt(
                allowanceId: Fixtures.walletAllowanceId,
                amountSats: 2000,
                admittedAt: Fixtures.utc("2026-09-05T10:00:00Z"),
                isLive: true
            ),
        ])
    }

    // MARK: Trusted time vs demo clock

    func testStatusAndCapacityUseInjectedTimeWhileDemoClockIsOffset() throws {
        snapshotAppDefaults(DemoClock.offsetDaysKey)
        UserDefaults.standard.set(365, forKey: DemoClock.offsetDaysKey)
        try XCTSkipUnless(DemoClock.offsetDays() == 365, "The demo clock is unavailable in this build")
        let realNow = Date()
        XCTAssertGreaterThan(DemoClock.subscriptionNow(), realNow.addingTimeInterval(364 * 24 * 60 * 60))

        let allowance = Fixtures.allowance(expiresAt: Fixtures.now.addingTimeInterval(30 * 24 * 60 * 60))
        XCTAssertEqual(allowance.status(at: Fixtures.now), .active)

        let attempts = [Fixtures.capacityAttempt(sats: 50000, at: "2026-09-10T10:00:00Z")]
        XCTAssertEqual(Fixtures.usedSats(attempts), 50000)
        XCTAssertFalse(PaykitAllowanceCapacity.fits(amountSats: 1, allowance: allowance, attempts: attempts, now: Fixtures.now))
    }

    // MARK: Grouping

    @MainActor
    func testOrderedReceiverPathsPutTheWalletLinkFirst() {
        XCTAssertEqual(
            PaykitAllowanceManager.orderedReceiverPaths([
                PaykitReceiverPath.server,
                "a/other",
                PaykitReceiverPath.wallet,
                PaykitReceiverPath.server,
            ]),
            [PaykitReceiverPath.wallet, "a/other", PaykitReceiverPath.server]
        )
        XCTAssertEqual(PaykitAllowanceManager.orderedReceiverPaths([PaykitReceiverPath.server]), [PaykitReceiverPath.server])
        XCTAssertEqual(PaykitAllowanceManager.orderedReceiverPaths([]), [])
    }

    func testEntryPrimaryPrefersTheWalletLink() {
        let server = Fixtures.allowance(allowanceId: Fixtures.serverAllowanceId, receiverPath: PaykitReceiverPath.server, perPaymentMaxSats: 1)
        let wallet = Fixtures.allowance(allowanceId: Fixtures.walletAllowanceId, receiverPath: PaykitReceiverPath.wallet)

        let entry = PaykitAllowanceEntry(id: "group", allowances: [server, wallet], limits: Fixtures.limits)
        XCTAssertEqual(entry.primary.allowanceId, Fixtures.walletAllowanceId)
        XCTAssertEqual(entry.perPaymentMaxSats, 5000)

        let serverOnly = PaykitAllowanceEntry(id: "server", allowances: [server], limits: nil)
        XCTAssertEqual(serverOnly.primary.allowanceId, Fixtures.serverAllowanceId)
    }
}

/// Shared builders for the Allowance suites.
enum PaykitAllowanceFixtures {
    static let identityKey = "pubky\(String(repeating: "z", count: 52))"
    static let counterpartyKey = "pubky\(String(repeating: "y", count: 52))"
    static let otherCounterpartyKey = "pubky\(String(repeating: "x", count: 52))"
    static let walletAllowanceId = "allowance-wallet"
    static let serverAllowanceId = "allowance-server"
    static let lightningIdentifier = PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
    static let onchainIdentifier = PublicPaykitService.MethodId.bitcoinOnchainP2wpkh.rawValue
    static let now = utc("2026-09-24T12:00:00Z")
    static let septemberAnchor = utc("2026-09-01T00:00:00Z")
    static let limits = PaykitAllowanceLimits(perPaymentUsd: 5, monthlyUsd: 50, perPaymentSats: 5000, monthlySats: 50000)

    static func utc(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            preconditionFailure("Invalid fixture timestamp \(value)")
        }
        return date
    }

    static func standardTerms() throws -> Paykit.AllowanceTerms {
        try limits.terms(monthAnchor: septemberAnchor, allowedPaymentEndpointIdentifiers: [lightningIdentifier])
    }

    static func customTerms(activeFrom: Date? = nil, expiresAt: Date? = nil) throws -> Paykit.AllowanceTerms {
        try Paykit.AllowanceTerms(
            asset: PaykitIssuerInterop.bitcoinAsset,
            perPaymentAmount: Paykit.AllowanceAmountRange(minimum: "0", maximum: "0.00005"),
            periodLimits: [
                Paykit.AllowancePeriodLimit(
                    amountLimit: "0.0005",
                    paymentCountLimit: nil,
                    period: Paykit.AllowancePeriod(kind: "anchored", every: 1, unit: "month", anchor: "2026-09-01T00:00:00Z")
                ),
            ],
            lifetimeAmountLimit: nil,
            activeFrom: activeFrom.map(PaykitAllowanceTime.format),
            expiresAt: expiresAt.map(PaykitAllowanceTime.format),
            allowedPaymentEndpointIdentifiers: [lightningIdentifier]
        )
    }

    static func record(
        allowanceId: String = walletAllowanceId,
        counterparty: String = counterpartyKey,
        receiverPath: String = PaykitReceiverPath.wallet,
        localRole: Paykit.AllowanceLocalRole? = .allower,
        state: Paykit.AllowanceLifecycleState = .accepted,
        historyStatus: Paykit.AllowanceHistoryStatus = .consistent,
        terms: Paykit.AllowanceTerms?,
        proposedByMe: Bool = true,
        lastEventAt: String? = "2026-09-02T10:00:00Z"
    ) -> Paykit.AllowanceRecord {
        Paykit.AllowanceRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: receiverPath,
            allowanceId: allowanceId,
            localRole: localRole,
            state: state,
            historyStatus: historyStatus,
            proposalEventId: "proposal-\(allowanceId)",
            terms: terms,
            proposalStreamItemId: proposedByMe ? nil : 1,
            proposalOutboundMessageId: proposedByMe ? 1 : nil,
            proposalOutboundStatus: nil,
            acceptanceEventId: nil,
            acceptanceOutboundStatus: nil,
            rejectionEventId: nil,
            rejectionOutboundStatus: nil,
            endEventId: nil,
            endOutboundStatus: nil,
            pendingCausalEventIds: [],
            conflictEventIds: [],
            lastStreamItemId: nil,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: lastEventAt,
            invalidReason: nil
        )
    }

    static func allowance(
        allowanceId: String = walletAllowanceId,
        counterparty: String = counterpartyKey,
        receiverPath: String = PaykitReceiverPath.wallet,
        role: PaykitAllowance.Role = .allower,
        state: Paykit.AllowanceLifecycleState = .accepted,
        perPaymentMaxSats: UInt64? = 5000,
        monthlyLimitSats: UInt64? = 50000,
        monthlyAnchor: Date? = septemberAnchor,
        expiresAt: Date? = nil
    ) -> PaykitAllowance {
        PaykitAllowance(
            id: PaykitAllowance.ID(counterparty: counterparty, counterpartyReceiverPath: receiverPath, allowanceId: allowanceId),
            role: role,
            lifecycleState: state,
            isProposedByMe: role == .allower,
            perPaymentMaxSats: perPaymentMaxSats,
            monthlyLimitSats: monthlyLimitSats,
            monthlyAnchor: monthlyAnchor,
            expiresAt: expiresAt,
            allowedPaymentEndpointIdentifiers: [lightningIdentifier]
        )
    }

    static func capacityAttempt(
        allowanceId: String = walletAllowanceId,
        sats: UInt64,
        at timestamp: String,
        isLive: Bool = true
    ) -> PaykitAllowanceCapacity.Attempt {
        PaykitAllowanceCapacity.Attempt(allowanceId: allowanceId, amountSats: sats, admittedAt: utc(timestamp), isLive: isLive)
    }

    static func usedSats(_ attempts: [PaykitAllowanceCapacity.Attempt]) -> UInt64 {
        PaykitAllowanceCapacity.usedSats(allowanceId: walletAllowanceId, attempts: attempts, anchor: septemberAnchor, now: now)
    }

    static func attemptRecord(
        id: String,
        mode: Paykit.PaymentExecutionMode = .automatic,
        allowanceId: String? = walletAllowanceId,
        amount: String = "0.00001",
        admittedAt: String = "2026-09-24T12:00:00Z",
        status: Paykit.PaymentExecutionStatus,
        epoch: String = "epoch-1"
    ) throws -> Paykit.PaymentAttemptRecord {
        try Paykit.PaymentAttemptRecord(
            attemptId: id,
            mode: mode,
            allowanceId: allowanceId,
            associationRevision: allowanceId == nil ? nil : 1,
            amount: Paykit.AccountingAmount(value: amount, asset: PaykitIssuerInterop.bitcoinAsset),
            admittedAt: admittedAt,
            status: status,
            epoch: epoch
        )
    }

    static func accountingScope(_ paymentRequestId: String) -> Paykit.PaymentAccountingScope {
        Paykit.PaymentAccountingScope(
            localPublicKey: identityKey,
            localReceiverPath: PaykitReceiverPath.wallet,
            counterparty: counterpartyKey,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            paymentRequestId: paymentRequestId
        )
    }

    static func occurrence(
        requestId: String,
        attempts: [Paykit.PaymentAttemptRecord],
        allowanceId: String? = walletAllowanceId
    ) -> Paykit.PaymentOccurrenceRecord {
        Paykit.PaymentOccurrenceRecord(
            key: Paykit.PaymentOccurrenceKey(request: accountingScope(requestId), billingPeriod: nil),
            disposition: .automatic,
            allowanceId: allowanceId,
            associationRevision: allowanceId == nil ? nil : 1,
            attempts: attempts
        )
    }

    static func accountingState(
        revision: UInt64 = 1,
        epoch: String = "epoch-1",
        requiresReconciliation: Bool = false,
        occurrences: [Paykit.PaymentOccurrenceRecord] = []
    ) -> Paykit.AllowanceAccountingState {
        Paykit.AllowanceAccountingState(
            revision: revision,
            epoch: epoch,
            requiresReconciliation: requiresReconciliation,
            history: Paykit.AllowanceAccountingHistory(associations: [], occurrences: occurrences, watermarks: [])
        )
    }

    static func paymentRequest(
        id: String = "550e8400-e29b-41d4-a716-446655440001",
        counterparty: String = counterpartyKey,
        receiverPath: String = PaykitReceiverPath.wallet,
        amount: String = "0.00001",
        createdAt: String = "2026-09-24T11:00:00Z"
    ) throws -> PaykitPaymentRequest {
        let record = try Paykit.PaymentRequestRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: receiverPath,
            paymentRequestId: id,
            localRole: .payer,
            state: .proposed,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            terms: Paykit.PaymentRequestTerms(
                amount: Paykit.PaymentRequestAmount(value: amount, asset: PaykitIssuerInterop.bitcoinAsset),
                paymentReference: Paykit.PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: [lightningIdentifier],
                metadata: Paykit.PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: createdAt,
            invalidReason: nil
        )
        return try XCTUnwrap(PaykitPaymentRequest(record: record, now: now, network: .regtest))
    }
}
