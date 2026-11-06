@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class ChannelFreeRailTests: XCTestCase {
    private var rail: FakeRail!
    private var previousRail: Bitkit.ChannelFreeLightningRail?

    override func setUp() {
        super.setUp()
        rail = FakeRail()
        previousRail = Bitkit.LightningService.shared.channelFreeRail
        Bitkit.LightningService.shared.channelFreeRail = rail
    }

    override func tearDown() {
        Bitkit.LightningService.shared.clearEventCallback()
        Bitkit.LightningService.shared.channelFreeRail = previousRail
        rail = nil
        super.tearDown()
    }

    func testRailEventsBeforeTheNodeCallbackAreDeliveredOnceItIsSet() {
        let hash = "aa"
        Bitkit.LightningService.shared.emitChannelFreeRailEvent(
            .paymentReceived(paymentId: hash, paymentHash: hash, amountMsat: 1000, customRecords: [])
        )
        var received: [String] = []

        Bitkit.LightningService.shared.setEventCallback { event in
            if case let .paymentReceived(_, paymentHash, _, _) = event {
                received.append(paymentHash)
            }
        }

        XCTAssertEqual(received, [hash])
    }

    func testPaykitProofSettlesFromTheRailWhenTheEventWasMissed() async {
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: "bb", direction: .outbound, status: .succeeded, preimage: "cc")]

        let status = await PaykitLightningPaymentProofLookup().status(paymentHash: "BB")

        guard case let .succeeded(preimage) = status else { return XCTFail("Expected a settled proof, got \(status)") }
        XCTAssertEqual(preimage, "cc")
    }

    func testPrivatePaykitSeesRailReceivesAndSends() async throws {
        rail.payments = [
            Bitkit.ChannelFreeRailPayment(paymentHash: "in", direction: .inbound, status: .succeeded, preimage: nil),
            Bitkit.ChannelFreeRailPayment(paymentHash: "out", direction: .outbound, status: .pending, preimage: nil),
            Bitkit.ChannelFreeRailPayment(paymentHash: "failed", direction: .outbound, status: .failed, preimage: nil),
        ]

        let received = await PrivatePaykitService.shared.receivedSettledPaymentHashes()
        let attempted = try await PrivatePaykitService.shared.attemptedOutboundBolt11PaymentHashes()

        XCTAssertTrue(received.contains("in"))
        XCTAssertEqual(attempted.intersection(["out", "failed"]), ["out"])
    }

    func testLightningWaitFinishesWhenTheRailSettledBeforeWatching() async throws {
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: "ff", direction: .outbound, status: .succeeded, preimage: nil)]

        let settled = try await WalletViewModel().waitForLightningPayment(hash: "ff", timeoutSeconds: 5)

        XCTAssertEqual(settled.paymentHash, "ff")
    }

    func testQuickPayReconcilesRailPayments() {
        let row = QuickPayReconcileRow(railPayment: Bitkit.ChannelFreeRailPayment(
            paymentHash: "dd", direction: .outbound, status: .succeeded, preimage: nil
        ))

        XCTAssertEqual(row.invoicePaymentHash, "dd")
        XCTAssertTrue(row.isOutboundBolt11)
        XCTAssertEqual(row.status, QuickPayReconcileRow.Status.succeeded)
    }

    func testRailSendHonoursTheRoutingFeeLimit() async throws {
        rail.routingFeeSats = 5
        let limit = RouteParametersConfig(
            maxTotalRoutingFeeMsat: 1000, maxTotalCltvExpiryDelta: 1008, maxPathCount: 10, maxChannelSaturationPowerOfHalf: 2
        )

        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: "lnbcrt1rail", sats: 100, params: limit)
            XCTFail("Expected the fee limit to stop the payment")
        } catch {
            XCTAssertTrue(error is Bitkit.ChannelFreeRailSendRefused, "A refusal before sending must read as never left: \(error)")
            XCTAssertNil(rail.sentBolt11)
        }

        let roomy = RouteParametersConfig(
            maxTotalRoutingFeeMsat: 10000, maxTotalCltvExpiryDelta: 1008, maxPathCount: 10, maxChannelSaturationPowerOfHalf: 2
        )
        _ = try await Bitkit.LightningService.shared.send(bolt11: "lnbcrt1rail", sats: 100, params: roomy)
        XCTAssertEqual(rail.sentBolt11, "lnbcrt1rail")
        XCTAssertEqual(rail.sentFeeLimitSats, 10, "The rail checks its sent quote against the limit too")
    }
}

@MainActor
extension ChannelFreeRailTests {
    func testFailedFeeEstimateIsARefusalBeforeSending() async {
        rail.estimateError = NSError(domain: "spark", code: 1)
        let limit = RouteParametersConfig(
            maxTotalRoutingFeeMsat: 1000, maxTotalCltvExpiryDelta: 1008, maxPathCount: 10, maxChannelSaturationPowerOfHalf: 2
        )

        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: "lnbcrt1rail", sats: 100, params: limit)
            XCTFail("Expected the failed estimate to stop the payment")
        } catch {
            XCTAssertTrue(error is Bitkit.ChannelFreeRailSendRefused)
            XCTAssertNil(rail.sentBolt11)
        }
    }

    func testCanSendLeavesRoomForTheSparkFee() {
        rail.balanceSats = 100_000
        let sendable = Bitkit.ChannelFreeRailFees.sendableSats(balanceSats: 100_000)

        XCTAssertEqual(rail.sendableSats, sendable)
        XCTAssertTrue(Bitkit.LightningService.shared.canSend(amountSats: sendable))
        XCTAssertFalse(Bitkit.LightningService.shared.canSend(amountSats: 100_000))
    }

    func testSendableSatsFitsTheFeeBesideTheAmount() {
        for balance: UInt64 in [0, 1, 400, 401, 9572, 100_000, 21_000_000] {
            let sendable = Bitkit.ChannelFreeRailFees.sendableSats(balanceSats: balance)
            let fee = (sendable * Bitkit.ChannelFreeRailFees.serviceFeePpm + 999_999) / 1_000_000
            XCTAssertLessThanOrEqual(sendable + fee, balance, "\(balance)")
            let next = sendable + 1
            let nextFee = (next * Bitkit.ChannelFreeRailFees.serviceFeePpm + 999_999) / 1_000_000
            XCTAssertGreaterThan(next + nextFee, balance, "\(balance) leaves room for more")
        }
        XCTAssertEqual(Bitkit.ChannelFreeRailFees.sendableSats(balanceSats: 100_000), 99750)
    }

    func testDuplicatePaymentCheckFailsClosedWhenTheRailCannotListItsPayments() async {
        rail.listError = NSError(domain: "spark", code: 1)

        let attempted = await PrivatePaykitService.shared.hasAttemptedOutboundBolt11Payment(paymentHash: "out")
        let proof = await PaykitLightningPaymentProofLookup.railStatus(paymentHash: "out")

        XCTAssertNil(attempted, "An unknown attempt must not read as never paid")
        guard case .unavailable = proof else { return XCTFail("Expected an unavailable proof, got \(proof)") }
    }

    func testDuplicatePaymentCheckSeesARailAttempt() async {
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: "out", direction: .outbound, status: .pending, preimage: nil)]

        let attempted = await PrivatePaykitService.shared.hasAttemptedOutboundBolt11Payment(paymentHash: "out")
        let fresh = await PrivatePaykitService.shared.hasAttemptedOutboundBolt11Payment(paymentHash: "new")

        XCTAssertEqual(attempted, true)
        XCTAssertEqual(fresh, false)
    }

    func testRetriedInvoiceSettlesFromItsLiveAttempt() {
        let failed = Bitkit.ChannelFreeRailPayment(paymentHash: "aa", direction: .outbound, status: .failed, preimage: nil, timestamp: 20)
        let retry = Bitkit.ChannelFreeRailPayment(
            paymentHash: "AA", direction: .outbound, status: .succeeded, preimage: "pp", timestamp: 10, feeSats: 3
        )
        let received = Bitkit.ChannelFreeRailPayment(paymentHash: "aa", direction: .inbound, status: .pending, preimage: nil, timestamp: 30)

        let latest = Bitkit.ChannelFreeRailPayment.latestOutboundAttempt([failed, retry, received], paymentHash: "aa")

        XCTAssertEqual(latest, retry)
        XCTAssertEqual(Bitkit.ChannelFreeRailPayment.latestOutboundAttempt([failed], paymentHash: "aa"), failed)
    }

    func testSendableSatsDoesNotOverflowOnAHugeBalance() {
        let sendable = Bitkit.ChannelFreeRailFees.sendableSats(balanceSats: UInt64.max)

        XCTAssertLessThan(sendable, UInt64.max)
        XCTAssertGreaterThan(sendable, UInt64.max / 2)
    }

    func testSparkFailureDoesNotEndAChannelRetryOfTheSameInvoice() async throws {
        let hash = "a1a1"
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: hash, direction: .outbound, status: .failed, preimage: nil)]
        Bitkit.LightningService.shared.noteAttempt(on: .ldk, paymentHash: hash)
        let wallet = WalletViewModel()
        var failures = 0
        wallet.addOnEvent(id: "failures") { event in
            if case .paymentFailed = event {
                failures += 1
            }
        }
        Bitkit.LightningService.shared.setEventCallback { wallet.notifyEventHandlers($0) }

        let wait = Task { try await wallet.waitForLightningPayment(hash: hash, timeoutSeconds: 5) }
        try await Task.sleep(nanoseconds: 200_000_000)
        Bitkit.LightningService.shared.emitChannelFreeRailEvent(.paymentFailed(paymentId: hash, paymentHash: hash, reason: .unexpectedError))
        wallet.notifyEventHandlers(.paymentSuccessful(paymentId: hash, paymentHash: hash, paymentPreimage: "pp", feePaidMsat: 2000))
        let settled = try await wait.value

        XCTAssertEqual(settled.paymentHash, hash)
        XCTAssertEqual(failures, 0, "No failure may reach the send screen")
        wallet.removeOnEvent(id: "failures")
    }

    func testChannelFailureDoesNotEndASparkRetryOfTheSameInvoice() async throws {
        let hash = "b2b2"
        Bitkit.LightningService.shared.noteAttempt(on: .channelFree, paymentHash: hash)
        let wallet = WalletViewModel()
        Bitkit.LightningService.shared.setEventCallback { wallet.notifyEventHandlers($0) }
        let staleLdkFailure = LDKNode.Event.paymentFailed(paymentId: hash, paymentHash: hash, reason: .retriesExhausted)

        XCTAssertTrue(Bitkit.LightningService.shared.isStaleFailure(staleLdkFailure, from: .ldk), "The node loop drops it")
        let wait = Task { try await wallet.waitForLightningPayment(hash: hash, timeoutSeconds: 5) }
        try await Task.sleep(nanoseconds: 200_000_000)
        Bitkit.LightningService.shared.emitChannelFreeRailEvent(
            .paymentSuccessful(paymentId: hash, paymentHash: hash, paymentPreimage: "pp", feePaidMsat: 1000)
        )
        let settled = try await wait.value

        XCTAssertEqual(settled.paymentHash, hash)
    }

    func testSettledActivityKeepsItsStatusAgainstAStaleFailure() {
        XCTAssertTrue(ActivityService.keepsLightningStatus(existing: .succeeded, update: .failed, isStaleRailFailure: false))
        XCTAssertTrue(ActivityService.keepsLightningStatus(existing: .pending, update: .failed, isStaleRailFailure: true))
        XCTAssertFalse(ActivityService.keepsLightningStatus(existing: .pending, update: .failed, isStaleRailFailure: false))
        XCTAssertFalse(ActivityService.keepsLightningStatus(existing: .failed, update: .succeeded, isStaleRailFailure: false))
        XCTAssertFalse(ActivityService.keepsLightningStatus(existing: .pending, update: .succeeded, isStaleRailFailure: true))
    }

    func testRailRunsTheSubmissionCheckBeforeSending() async {
        struct Expired: Error {}

        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: "lnbcrt1rail", sats: 100) { throw Expired() }
            XCTFail("Expected the submission check to stop the payment")
        } catch {
            XCTAssertTrue(error is Expired)
            XCTAssertNil(rail.sentBolt11)
        }
    }

    func testProofSettlesFromTheRailOfTheLatestAttempt() {
        typealias Lookup = PaykitLightningPaymentProofLookup
        XCTAssertEqual(Lookup.combined(ldk: .failed, rail: .pending, latestAttempt: .channelFree), .pending)
        XCTAssertEqual(Lookup.combined(ldk: .failed, rail: .succeeded(preimage: "pp"), latestAttempt: .channelFree), .succeeded(preimage: "pp"))
        XCTAssertEqual(Lookup.combined(ldk: .failed, rail: .succeeded(preimage: "pp"), latestAttempt: nil), .succeeded(preimage: "pp"))
        XCTAssertEqual(Lookup.combined(ldk: .pending, rail: .failed, latestAttempt: .ldk), .pending)
        XCTAssertEqual(Lookup.combined(ldk: .failed, rail: .pending, latestAttempt: nil), .pending, "A retry may still be in flight")
        XCTAssertEqual(Lookup.combined(ldk: .failed, rail: .unavailable, latestAttempt: nil), .unavailable, "Spark could hold a retry")
        XCTAssertEqual(Lookup.combined(ldk: .failed, rail: .unknown, latestAttempt: nil), .failed)
        XCTAssertEqual(Lookup.combined(ldk: .unknown, rail: .unknown, latestAttempt: nil), .unknown)
    }

    func testQuickPayPrefersTheLiveAttemptAcrossRails() {
        let record = QuickPayLedgerRecord(amountCents: 100, dayKey: "2026-11-06", invoicePaymentHash: "cc", paymentId: "cc")
        let ldkFailed = QuickPayReconcileRow(paymentId: "cc", invoicePaymentHash: "cc", isOutboundBolt11: true, status: .failed)
        let sparkPaid = QuickPayReconcileRow(railPayment: Bitkit.ChannelFreeRailPayment(
            paymentHash: "cc", direction: .outbound, status: .succeeded, preimage: nil
        ))

        XCTAssertEqual(QuickPaySpendStore.ledgerMatch(record: record, rows: [ldkFailed, sparkPaid])?.status, .succeeded)
    }

    func testSparkReadyTriggersOnceUntilItDropsAgain() {
        var transition = SparkReadinessTransition()
        XCTAssertFalse(transition.becameReady(false))
        XCTAssertTrue(transition.becameReady(true))
        XCTAssertFalse(transition.becameReady(true))
        XCTAssertFalse(transition.becameReady(false))
        XCTAssertTrue(transition.becameReady(true))
    }
}

private final class FakeRail: Bitkit.ChannelFreeLightningRail {
    var isReady = true
    var balanceSats: UInt64 = 9572
    var payments: [Bitkit.ChannelFreeRailPayment] = []
    var routingFeeSats: UInt64 = 0
    var estimateError: Error?
    var listError: Error?
    var sentBolt11: String?
    var sentFeeLimitSats: UInt64?

    func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String {
        "lnbcrt1fake"
    }

    func send(bolt11: String, sats: UInt64?, maxFeeSats: UInt64?, beforeSubmission: @escaping () throws -> Void) async throws -> PaymentHash {
        try beforeSubmission()
        sentFeeLimitSats = maxFeeSats
        sentBolt11 = bolt11
        return "ee"
    }

    func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64 {
        if let estimateError {
            throw estimateError
        }
        return routingFeeSats
    }

    func lightningPayments() async throws -> [Bitkit.ChannelFreeRailPayment] {
        if let listError {
            throw listError
        }
        return payments
    }
}
