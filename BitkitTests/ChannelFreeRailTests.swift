@testable import Bitkit
import BreezSdkSpark
import LDKNode
import XCTest

@MainActor
final class ChannelFreeRailTests: XCTestCase {
    /// A 20 000 sat regtest invoice, so a payment can be looked up by its hash.
    static let invoice =
        "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"

    private var rail: FakeRail!
    private var previousRail: Bitkit.ChannelFreeLightningRail?
    private var previousAttemptsStore: UserDefaults!
    private var previousRailSupported: (() async -> Bool)!
    private var previousNow: (() -> Date)!

    override func setUp() {
        super.setUp()
        rail = FakeRail()
        let service = Bitkit.LightningService.shared
        previousRail = service.channelFreeRail
        service.channelFreeRail = rail
        previousAttemptsStore = service.railAttemptsStore
        service.railAttemptsStore = UserDefaults(suiteName: "ChannelFreeRailTests")!
        service.forgetRailAttempts()
        service.forgetLdkAttempts()
        previousRailSupported = service.channelFreeRailSupported
        service.channelFreeRailSupported = { true }
        previousNow = service.now
    }

    override func tearDown() {
        let service = Bitkit.LightningService.shared
        service.forgetRailAttempts()
        service.forgetLdkAttempts()
        service.railAttemptsStore = previousAttemptsStore
        service.channelFreeRailSupported = previousRailSupported
        service.now = previousNow
        service.clearEventCallback()
        service.channelFreeRail = previousRail
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
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        service.nodePayments = { [] }
        defer { service.nodePayments = nodePayments }

        let received = await PrivatePaykitService.shared.receivedSettledPaymentHashes()
        let attempted = try await PrivatePaykitService.shared.attemptedOutboundBolt11PaymentHashes()

        XCTAssertTrue(received.contains("in"))
        XCTAssertEqual(attempted.intersection(["out", "failed"]), ["out"])
    }

    func testAContactListInvoicePaidOnSparkReadsAsSettled() async {
        // The private payment list's invoice was created on Spark, so only Spark's list shows it paid.
        let hash = String(repeating: "ab", count: 32)
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: hash, direction: .inbound, status: .pending, preimage: nil)]
        let pending = await PrivatePaykitService.shared.isReceivedInvoiceSettled(paymentHash: hash)
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: hash, direction: .inbound, status: .succeeded, preimage: nil)]

        let paid = await PrivatePaykitService.shared.isReceivedInvoiceSettled(paymentHash: hash)

        XCTAssertFalse(pending)
        XCTAssertTrue(paid, "A paid Spark invoice would leave the private list unrotated")
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

    func testAnInvoiceTheNodeIsStillPayingIsNotSentAgainThroughSpark() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let inFlight = LDKNode.PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: Self.invoice),
            amountMsat: 20_000_000, feePaidMsat: nil, direction: .outbound, status: .pending, latestUpdateTimestamp: 0
        )
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        service.nodePayments = { [inFlight] }
        defer { service.nodePayments = nodePayments }
        // The HTLC in flight leaves the channel too little outbound, so the retry falls to Spark.
        rail.balanceSats = 100_000

        do {
            _ = try await service.send(bolt11: Self.invoice)
            XCTFail("Expected the pending node payment to refuse the retry")
        } catch {
            XCTAssertTrue(PrivatePaykitService.isDuplicatePaymentError(error), "\(error)")
        }
        XCTAssertNil(rail.sentBolt11)
    }

    func testAnInvoiceSentOverTheNodeIsNotSentThroughSparkWhileTheNodeCantListIt() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        service.nodePayments = { nil }
        defer { service.nodePayments = nodePayments }
        service.recordLdkAttempt(paymentHash: hash)
        rail.balanceSats = 100_000

        do {
            _ = try await service.send(bolt11: Self.invoice)
            XCTFail("Expected the node attempt it can't list to refuse the Spark send")
        } catch {
            XCTAssertTrue(PrivatePaykitService.isDuplicatePaymentError(error), "\(error)")
        }
        XCTAssertNil(rail.sentBolt11)
    }

    func testSparkStillPaysWhileTheNodeCantListWhenTheNodeNeverTriedTheInvoice() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        service.nodePayments = { nil }
        defer { service.nodePayments = nodePayments }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        XCTAssertEqual(rail.sentBolt11, Self.invoice)
    }

    func testSparkWaitsForTheNodesFirstListingWhenItsEarlierPaymentsWereNeverKept() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        // Node payments made before their hashes were kept: none is held until the node lists them.
        service.railAttemptsStore.removeObject(forKey: Bitkit.LightningService.ldkAttemptsSeededKey)
        rail.balanceSats = 100_000

        service.nodePayments = { nil }
        do {
            _ = try await service.send(bolt11: Self.invoice)
            XCTFail("Spark paid while the node's earlier payments were unknown")
        } catch {}
        XCTAssertNil(rail.sentBolt11)

        service.nodePayments = { [] }
        _ = try await service.send(bolt11: Self.invoice)
        rail.sentBolt11 = nil
        service.nodePayments = { nil }
        _ = try await service.send(bolt11: Self.invoice)

        XCTAssertEqual(rail.sentBolt11, Self.invoice, "Spark stayed held after the node listed its payments")
    }

    func testANodePaymentMadeBeforeHashesWereKeptHoldsSparkOnceTheNodeListedIt() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let pending = LDKNode.PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: Self.invoice),
            amountMsat: 20_000_000, feePaidMsat: nil, direction: .outbound, status: .pending, latestUpdateTimestamp: 0
        )
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        service.railAttemptsStore.removeObject(forKey: Bitkit.LightningService.ldkAttemptsSeededKey)
        rail.balanceSats = 100_000

        service.nodePayments = { [pending] }
        do {
            _ = try await service.send(bolt11: Self.invoice)
        } catch {}
        service.nodePayments = { nil }
        do {
            _ = try await service.send(bolt11: Self.invoice)
            XCTFail("Expected the node's pending payment to hold Spark while the node can't list it")
        } catch {
            XCTAssertTrue(PrivatePaykitService.isDuplicatePaymentError(error), "\(error)")
        }
        XCTAssertNil(rail.sentBolt11)
    }

    func testANodeAttemptTheNodeListsAsFailedNoLongerHoldsSpark() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let failed = LDKNode.PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: Self.invoice),
            amountMsat: 20_000_000, feePaidMsat: nil, direction: .outbound, status: .failed, latestUpdateTimestamp: 0
        )
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        service.recordLdkAttempt(paymentHash: hash)
        rail.balanceSats = 100_000

        service.nodePayments = { [failed] }
        _ = try await service.send(bolt11: Self.invoice)
        rail.sentBolt11 = nil
        service.nodePayments = { nil }
        _ = try await service.send(bolt11: Self.invoice)

        XCTAssertEqual(rail.sentBolt11, Self.invoice, "A failed node attempt kept holding the invoice")
    }

    func testAPendingNodePaymentBehindTheCapOfSettledOnesStillHoldsSparkWhileTheNodeCantList() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let pending = LDKNode.PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: Self.invoice),
            amountMsat: 20_000_000, feePaidMsat: nil, direction: .outbound, status: .pending, latestUpdateTimestamp: 0
        )
        let settled = (1 ... 500).map { index in
            LDKNode.PaymentDetails(
                id: Self.otherHash(index), kind: .bolt11(hash: Self.otherHash(index), preimage: nil, secret: nil, description: nil, bolt11: ""),
                amountMsat: 1000, feePaidMsat: nil, direction: .outbound, status: .succeeded, latestUpdateTimestamp: UInt64(index)
            )
        }
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        service.railAttemptsStore.removeObject(forKey: Bitkit.LightningService.ldkAttemptsSeededKey)
        rail.balanceSats = 100_000

        service.nodePayments = { [pending] + settled }
        _ = try? await service.send(bolt11: Self.invoice)
        service.nodePayments = { nil }

        await assertRefusedAsDuplicate()
    }

    func testANodeSendStillPendingBehindTheCapOfLaterSendsStillHoldsSparkWhileTheNodeCantList() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        service.nodePayments = { nil }
        defer { service.nodePayments = nodePayments }
        service.recordLdkAttempt(paymentHash: hash)
        for index in 1 ... 500 {
            service.recordLdkAttempt(paymentHash: Self.otherHash(index))
        }
        rail.balanceSats = 100_000

        await assertRefusedAsDuplicate()
    }

    func testASparkSendStillPendingBehindTheCapOfLaterSendsStillHoldsTheNode() async throws {
        try await sendOverSpark()
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let service = Bitkit.LightningService.shared
        for index in 1 ... 500 {
            service.recordRailAttempt(paymentHash: Self.otherHash(index))
        }
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: hash, direction: .outbound, status: .pending, preimage: nil)]
            + (1 ... 500).map {
                Bitkit.ChannelFreeRailPayment(paymentHash: Self.otherHash($0), direction: .outbound, status: .succeeded, preimage: nil)
            }
        rail.balanceSats = 0
        await assertRefusedAsDuplicate()

        rail.listError = NSError(domain: "spark", code: 1)

        await assertRefusedAsDuplicate()
    }

    func testANodeHashListedOnlyAsFailedIsDropped() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        service.recordLdkAttempt(paymentHash: Self.otherHash(1))
        service.nodePayments = { [Self.nodePayment(Self.otherHash(1), status: .failed)] }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        let kept = service.railAttemptsStore.stringArray(forKey: Self.ldkAttemptsKey) ?? []
        XCTAssertFalse(kept.contains(Self.otherHash(1)), "A node hash listed only as failed was kept")
    }

    func testNodeHashesListedOnlyAsFailedAreDroppedPastTheCapToo() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        let pending = Self.nodePayment(Self.otherHash(0), status: .pending)
        let failed = (1 ... 501).map { Self.nodePayment(Self.otherHash($0), status: .failed) }
        ([pending] + failed).forEach { service.recordLdkAttempt(paymentHash: $0.id) }
        service.nodePayments = { [pending] + failed }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        let kept = service.railAttemptsStore.stringArray(forKey: Self.ldkAttemptsKey) ?? []
        XCTAssertEqual(kept, [Self.otherHash(0)], "Failed node hashes stayed, or the pending one was dropped")
    }

    func testANodeRetryRecordedDuringAnOlderListingSurvivesItsTrim() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        let retried = Self.otherHash(0)
        let failed = (0 ... 500).map { Self.nodePayment(Self.otherHash($0), status: .failed) }
        failed.forEach { service.recordLdkAttempt(paymentHash: $0.id) }
        // The node retries the oldest failed invoice while this listing, which still shows it failed, is read.
        service.nodePayments = {
            service.recordLdkAttempt(paymentHash: retried)
            return failed
        }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        let kept = service.railAttemptsStore.stringArray(forKey: Self.ldkAttemptsKey) ?? []
        XCTAssertEqual(kept, [retried], "Failed node hashes stayed, or an older listing dropped the retry in flight")
    }

    func testANodeRetryOfTheSameInvoiceRecordedDuringAnOlderListingKeepsItsHold() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        service.recordLdkAttempt(paymentHash: hash)
        // The node retries the invoice Spark is about to pay, and the retry returns, while this listing is read.
        service.nodePayments = {
            service.recordLdkAttempt(paymentHash: hash)
            return [Self.nodePayment(hash, status: .failed)]
        }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        let kept = service.railAttemptsStore.stringArray(forKey: Self.ldkAttemptsKey) ?? []
        XCTAssertEqual(kept, [hash], "An older listing released the node retry's hold")
    }

    func testASparkRetryRecordedDuringAnOlderListingKeepsItsHold() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let service = Bitkit.LightningService.shared
        service.recordRailAttempt(paymentHash: hash)
        service.recordRailAttempt(paymentHash: Self.otherHash(1))
        // Spark retries both invoices, and the retries return, while this listing, which still shows them failed, is read.
        rail.payments = [hash, Self.otherHash(1)].map {
            Bitkit.ChannelFreeRailPayment(paymentHash: $0, direction: .outbound, status: .failed, preimage: nil)
        }
        rail.onList = { [hash] in
            service.recordRailAttempt(paymentHash: hash)
            service.recordRailAttempt(paymentHash: Self.otherHash(1))
        }
        rail.balanceSats = 0

        await assertReachesTheNode()

        let kept = service.railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
        XCTAssertEqual(kept, [hash, Self.otherHash(1)], "An older listing dropped the hold of a Spark retry")
    }

    func testASparkRetryInFlightWhenAnOlderListingIsReadKeepsItsHoldAfterItEnds() async {
        let service = Bitkit.LightningService.shared
        let retried = Self.otherHash(1)
        service.recordRailAttempt(paymentHash: retried)
        XCTAssertTrue(service.beginRailSend(paymentHash: retried))
        // A Spark retry recorded before this listing ends while the listing, which still shows it failed, is read.
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: retried, direction: .outbound, status: .failed, preimage: nil)]
        rail.onList = { service.endRailSend(paymentHash: retried) }
        rail.balanceSats = 0

        await assertReachesTheNode()

        let kept = service.railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
        XCTAssertEqual(kept, [retried], "An older listing dropped the hold of a Spark retry that ended while it was read")
    }

    func testANodeRetryInFlightWhenAnOlderListingIsReadKeepsItsHoldAfterItEnds() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        let retried = Self.otherHash(0)
        service.recordLdkAttempt(paymentHash: retried)
        service.beginLdkSend(paymentHash: retried)
        // A node retry recorded before this listing ends while the listing, which still shows it failed, is read.
        service.nodePayments = {
            service.endLdkSend(paymentHash: retried)
            return [Self.nodePayment(retried, status: .failed)]
        }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        let kept = service.railAttemptsStore.stringArray(forKey: Self.ldkAttemptsKey) ?? []
        XCTAssertEqual(kept, [retried], "An older listing dropped the hold of a node retry that ended while it was read")
    }

    func testSendsNoListingShowsAreDroppedOnceTheirInvoiceExpiredPastTheSettleWindow() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        let window = 14 * 24 * 60 * 60
        let now = 10 * window
        service.now = { Date(timeIntervalSince1970: TimeInterval(now)) }
        for key in [Self.railAttemptsKey, Self.ldkAttemptsKey] {
            let record = key == Self.railAttemptsKey ? service.recordRailAttempt : service.recordLdkAttempt
            record(Self.otherHash(1), now - window)
            record(Self.otherHash(2), now - window + 1)
            record(Self.otherHash(3), nil)
        }
        // A send recorded while the listings are read is not in them yet.
        rail.onList = { service.recordRailAttempt(paymentHash: Self.otherHash(4), expiresAt: now - window) }
        service.nodePayments = {
            service.recordLdkAttempt(paymentHash: Self.otherHash(4), expiresAt: now - window)
            return []
        }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        for key in [Self.railAttemptsKey, Self.ldkAttemptsKey] {
            let kept = service.railAttemptsStore.stringArray(forKey: key) ?? []
            XCTAssertFalse(kept.contains(Self.otherHash(1)), "\(key) kept a send no listing shows past the settle window")
            XCTAssertTrue(
                Set([2, 3, 4].map(Self.otherHash)).isSubset(of: kept),
                "\(key) dropped a send that may be pending or has no known expiry"
            )
        }
    }

    func testASendWhoseInvoiceNeverExpiresKeepsItsHold() async throws {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        // An invoice whose expiry is past what an Int holds is kept at Int.max.
        service.recordRailAttempt(paymentHash: Self.otherHash(1), expiresAt: .max)
        service.recordLdkAttempt(paymentHash: Self.otherHash(1), expiresAt: .max)
        service.nodePayments = { [] }
        rail.balanceSats = 100_000

        _ = try await service.send(bolt11: Self.invoice)

        for key in [Self.railAttemptsKey, Self.ldkAttemptsKey] {
            let kept = service.railAttemptsStore.stringArray(forKey: key) ?? []
            XCTAssertTrue(kept.contains(Self.otherHash(1)), "\(key) dropped a send whose invoice never expires")
        }
    }

    func testSendsNoListingShowsWithNoKnownExpiryAreDroppedOldestFirstPastTheCap() async {
        let service = Bitkit.LightningService.shared
        (1 ... 501).forEach { service.recordRailAttempt(paymentHash: Self.otherHash($0)) }
        rail.balanceSats = 0

        await assertReachesTheNode()

        let kept = service.railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
        XCTAssertEqual(kept, (2 ... 501).map(Self.otherHash), "Spark hashes no listing shows grew past the cap")
    }

    func testAPendingNodePaymentBehindTheCapOfFailedOnesStillHoldsSparkWhileTheNodeCantList() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        defer { service.nodePayments = nodePayments }
        let failed = (1 ... 501).map { Self.nodePayment(Self.otherHash($0), status: .failed) }
        service.recordLdkAttempt(paymentHash: hash)
        failed.forEach { service.recordLdkAttempt(paymentHash: $0.id) }
        rail.balanceSats = 100_000

        service.nodePayments = { [Self.nodePayment(hash, status: .pending)] + failed }
        await assertRefusedAsDuplicate()
        service.nodePayments = { nil }

        await assertRefusedAsDuplicate()
    }

    func testAPaidSparkSendWhoseInvoiceIsUnexpiredStillHoldsTheNodeBehindTheCapWhileSparkCantList() async throws {
        let invoice = try Bolt11Invoice.fromStr(invoiceStr: Self.invoice)
        let service = Bitkit.LightningService.shared
        service.now = { Date(timeIntervalSince1970: TimeInterval(invoice.secondsSinceEpoch())) }
        try await sendOverSpark()
        try await listPaidSparkSendBehindTheCap(String(invoice.paymentHash()))

        rail.listError = NSError(domain: "spark", code: 1)

        await assertRefusedAsDuplicate()
    }

    func testAPaidSparkSendWhoseInvoiceExpiredIsTrimmedPastTheCap() async throws {
        let invoice = try Bolt11Invoice.fromStr(invoiceStr: Self.invoice)
        let hash = String(invoice.paymentHash())
        let service = Bitkit.LightningService.shared
        service.now = { Date(timeIntervalSince1970: TimeInterval(invoice.secondsSinceEpoch() + invoice.expiryTimeSeconds())) }
        try await sendOverSpark()

        try await listPaidSparkSendBehindTheCap(hash)

        let kept = service.railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
        XCTAssertEqual(kept.count, 500, "Paid Spark hashes stayed past the cap")
        XCTAssertFalse(kept.contains(hash), "The paid Spark hash whose invoice expired was kept")
    }

    func testSparkHashesListedFailedOnlyOrPaidWithAnExpiredInvoiceAreDroppedUnderTheCap() async {
        let service = Bitkit.LightningService.shared
        service.now = { Date(timeIntervalSince1970: 1000) }
        service.recordRailAttempt(paymentHash: Self.otherHash(1), expiresAt: 1000)
        service.recordRailAttempt(paymentHash: Self.otherHash(2), expiresAt: 1001)
        service.recordRailAttempt(paymentHash: Self.otherHash(3))
        service.recordRailAttempt(paymentHash: Self.otherHash(4))
        rail.payments = (1 ... 3).map {
            Bitkit.ChannelFreeRailPayment(paymentHash: Self.otherHash($0), direction: .outbound, status: .succeeded, preimage: nil)
        } + [Bitkit.ChannelFreeRailPayment(paymentHash: Self.otherHash(4), direction: .outbound, status: .failed, preimage: nil)]
        rail.balanceSats = 0

        await assertReachesTheNode()

        let kept = service.railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
        XCTAssertEqual(kept, [Self.otherHash(2), Self.otherHash(3)], "Expired or failed Spark hashes stayed, or live ones went")
    }

    /// Records 500 newer Spark sends after `hash` and lists them all as paid, so a node send trims past the cap.
    private func listPaidSparkSendBehindTheCap(_ hash: String) async throws {
        let service = Bitkit.LightningService.shared
        (1 ... 500).forEach { service.recordRailAttempt(paymentHash: Self.otherHash($0)) }
        rail.payments = ([hash] + (1 ... 500).map(Self.otherHash)).map {
            Bitkit.ChannelFreeRailPayment(paymentHash: $0, direction: .outbound, status: .succeeded, preimage: nil)
        }
        rail.balanceSats = 0
        _ = try? await service.send(bolt11: Self.invoice)
        rail.sentBolt11 = nil
    }

    func testSparkHashesListedAsFailedAreDroppedPastTheCapToo() async {
        let service = Bitkit.LightningService.shared
        (1 ... 501).forEach { service.recordRailAttempt(paymentHash: Self.otherHash($0)) }
        rail.payments = (1 ... 501).map {
            Bitkit.ChannelFreeRailPayment(paymentHash: Self.otherHash($0), direction: .outbound, status: .failed, preimage: nil)
        }
        rail.balanceSats = 0

        await assertReachesTheNode()

        let kept = service.railAttemptsStore.stringArray(forKey: Self.railAttemptsKey) ?? []
        XCTAssertEqual(kept, [], "Failed Spark hashes stayed")
    }

    func testASendSparkRefusedAfterItWasRecordedIsNotHeldWhileSparkCannotList() async {
        rail.balanceSats = 100_000
        rail.refusalAfterSubmission = Bitkit.ChannelFreeRailSendRefused(reason: "insufficient funds")
        _ = try? await Bitkit.LightningService.shared.send(bolt11: Self.invoice)
        rail.refusalAfterSubmission = nil
        rail.listError = NSError(domain: "spark", code: 1)
        rail.balanceSats = 0

        await assertReachesTheNode()
    }

    private static let ldkAttemptsKey = "ldkAttemptedPaymentHashes"
    private static let railAttemptsKey = "channelFreeRailAttemptedPaymentHashes"

    private static func nodePayment(_ hash: String, status: LDKNode.PaymentStatus) -> LDKNode.PaymentDetails {
        LDKNode.PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: ""),
            amountMsat: 1000, feePaidMsat: nil, direction: .outbound, status: status, latestUpdateTimestamp: 0
        )
    }

    private static func otherHash(_ index: Int) -> String {
        String(format: "%064x", index)
    }

    func testPaykitReadsAnUnlistableNodeAsUnknownNotAsNeverPaid() async {
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        service.nodePayments = { nil }
        defer { service.nodePayments = nodePayments }

        let attempted = await PrivatePaykitService.shared.hasAttemptedOutboundBolt11Payment(paymentHash: "out")

        XCTAssertNil(attempted)
    }

    func testQuickPayWaitsWhileTheNodeCantListItsPayments() async throws {
        let sparkFailure = Bitkit.ChannelFreeRailPayment(paymentHash: "aa", direction: .outbound, status: .failed, preimage: nil)

        let rows = try await QuickPayPaymentCoordinator.reconcileRows(railPayments: { [sparkFailure] }, nodePayments: { nil })

        XCTAssertNil(rows, "Spark's rows alone can release a record the node is still paying")
    }

    func testAnInvoiceSparkIsStillPayingIsNotSentAgainThroughTheNode() async {
        let hash = try? String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: hash ?? "", direction: .outbound, status: .pending, preimage: nil)]
        // Spark can't cover the retry, so it goes to the node.
        rail.balanceSats = 0

        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: Self.invoice)
            XCTFail("Expected the pending Spark payment to refuse the retry")
        } catch {
            XCTAssertTrue(PrivatePaykitService.isDuplicatePaymentError(error), "\(error)")
        }
        XCTAssertNil(rail.sentBolt11)
    }

    func testUserSendOverTheRailHasAFeeLimit() async throws {
        // WalletViewModel.send and sendWithTimeout pass no route parameters, so LDK applies its default
        // limit (1% + 50 sats); the rail must not be left without one.
        _ = try await Bitkit.LightningService.shared.send(bolt11: "lnbcrt1rail", sats: 1000)

        XCTAssertEqual(rail.sentBolt11, "lnbcrt1rail")
        XCTAssertNotNil(rail.sentFeeLimitSats, "A user send over Spark went out with no fee limit")
    }

    func testASparkSendStillInFlightIsNotSentAgainThroughTheNode() async throws {
        var release: CheckedContinuation<Void, Never>?
        rail.sendGate = { await withCheckedContinuation { release = $0 } }
        rail.balanceSats = 100_000
        let first = Task { try await Bitkit.LightningService.shared.send(bolt11: Self.invoice) }
        var waited = 0
        while release == nil, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertNotNil(release, "The Spark send never started")
        // Spark lists the send only once it returns; the retry falls to the node meanwhile.
        rail.balanceSats = 0

        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: Self.invoice)
            XCTFail("Expected the Spark send in flight to refuse the retry")
        } catch {
            XCTAssertTrue(PrivatePaykitService.isDuplicatePaymentError(error), "\(error)")
        }
        release?.resume()
        _ = try await first.value
    }

    func testAnInvoiceSparkTriedIsNotSentThroughTheNodeWhileSparkCannotListPayments() async throws {
        try await sendOverSpark()
        rail.listError = NSError(domain: "spark", code: 1)
        rail.balanceSats = 0

        await assertRefusedAsDuplicate()
    }

    func testAnInvoiceSparkTriedIsNotSentThroughTheNodeWhileSparkIsNotConnected() async throws {
        try await sendOverSpark()
        Bitkit.LightningService.shared.channelFreeRail = nil

        await assertRefusedAsDuplicate()
    }

    func testAnInvoiceSparkTriedGoesToTheNodeOnceSparkListsNoLiveAttempt() async throws {
        try await sendOverSpark()
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: hash, direction: .outbound, status: .failed, preimage: nil)]
        rail.balanceSats = 0

        await assertReachesTheNode()
    }

    func testAnInvoiceSparkNeverTriedGoesToTheNodeWhileSparkCannotListPayments() async {
        rail.listError = NSError(domain: "spark", code: 1)
        rail.balanceSats = 0

        await assertReachesTheNode()
    }

    func testAnInvoiceGoesToTheNodeWhenSparkIsUnsupported() async {
        let service = Bitkit.LightningService.shared
        service.channelFreeRail = nil
        service.channelFreeRailSupported = { false }

        await assertReachesTheNode()
    }

    func testASendSparkReportedFailedIsNotHeldFromTheNodeWhileSparkCannotList() async throws {
        try await sendOverSpark()
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        Bitkit.LightningService.shared.emitChannelFreeRailEvent(.paymentFailed(paymentId: hash, paymentHash: hash, reason: nil))
        rail.listError = NSError(domain: "spark", code: 1)
        rail.balanceSats = 0

        await assertReachesTheNode()
    }

    func testASendSparkListedAsFailedIsNotHeldOnceSparkCannotList() async throws {
        try await sendOverSpark()
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        rail.payments = [Bitkit.ChannelFreeRailPayment(paymentHash: hash, direction: .outbound, status: .failed, preimage: nil)]
        rail.balanceSats = 0
        await assertReachesTheNode()

        rail.listError = NSError(domain: "spark", code: 1)

        await assertReachesTheNode()
    }

    func testASendSparkRefusedBeforeDispatchIsNotHeldWhileSparkCannotList() async {
        rail.balanceSats = 100_000
        rail.refusal = Bitkit.ChannelFreeRailSendRefused(reason: "refused")
        _ = try? await Bitkit.LightningService.shared.send(bolt11: Self.invoice)
        rail.refusal = nil
        rail.listError = NSError(domain: "spark", code: 1)
        rail.balanceSats = 0

        await assertReachesTheNode()
    }

    func testSparkHistoryReadsAsUnavailableWhileSparkIsDisconnected() async {
        Bitkit.LightningService.shared.channelFreeRail = nil

        do {
            _ = try await Bitkit.LightningService.shared.channelFreeRailPayments()
            XCTFail("A disconnected Spark must not read as holding no payments")
        } catch {}
        let proof = await PaykitLightningPaymentProofLookup.railStatus(paymentHash: "out")
        guard case .unavailable = proof else { return XCTFail("Expected an unavailable proof, got \(proof)") }
        // After a restart an older failed channel attempt must not settle a Spark retry Spark can't list yet.
        XCTAssertEqual(PaykitLightningPaymentProofLookup.combined(ldk: .failed, rail: proof, latestAttempt: nil), .unavailable)
    }

    func testSparkHistoryReadsAsEmptyWhereSparkDoesNotRun() async throws {
        let service = Bitkit.LightningService.shared
        service.channelFreeRail = nil
        service.channelFreeRailSupported = { false }

        let payments = try await service.channelFreeRailPayments()

        XCTAssertTrue(payments.isEmpty)
    }

    func testAFixedWithdrawalWithAPartOfASatKeepsItsExactAmount() {
        typealias Route = Bitkit.LightningService.ReceiveRoute
        // A fixed LNURL withdrawal of 222 538 msat: channels that can take it get the exact amount; Spark can't, so
        // without such a channel it is refused rather than invoicing 222 000 msat, below the endpoint's minimum.
        XCTAssertEqual(Bitkit.LightningService.receiveRoute(amountMsats: 222_538, railTakes: false), Route.node)
        XCTAssertEqual(Bitkit.LightningService.receiveRoute(amountMsats: 222_538, railTakes: true), Route.refused)
        XCTAssertEqual(Bitkit.LightningService.receiveRoute(amountMsats: 222_000, railTakes: true), Route.rail(amountSats: 222))
    }

    func testAnAmountUnderASatIsNeverInvoicedAsAmountless() {
        typealias Route = Bitkit.LightningService.ReceiveRoute
        XCTAssertEqual(Bitkit.LightningService.receiveRoute(amountMsats: 500, railTakes: true), Route.refused)
        XCTAssertEqual(Bitkit.LightningService.receiveRoute(amountMsats: 500, railTakes: false), Route.node)
        XCTAssertEqual(Bitkit.LightningService.receiveRoute(amountMsats: nil, railTakes: true), Route.rail(amountSats: nil))
    }

    func testAChannelsOnlyPaymentNeverFallsBackToSpark() async {
        // The channels can't pay it (there are none in tests) and Spark could, as after a quote whose channel went away.
        rail.balanceSats = 100_000

        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: Self.invoice, channelsOnly: true)
            XCTFail("Expected the payment to fail on the channels")
        } catch {
            XCTAssertTrue("\(error)".contains("nodeNotSetup"), "\(error)")
        }
        XCTAssertNil(rail.sentBolt11, "A deselected Spark balance paid a channel-funded payment")
    }

    func testAHeldInvoiceIsNotReleasedWhileItsSparkRetryIsInFlight() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        var release: CheckedContinuation<Void, Never>?
        rail.sendGate = { await withCheckedContinuation { release = $0 } }
        rail.balanceSats = 100_000
        let retry = Task { try await Bitkit.LightningService.shared.send(bolt11: Self.invoice) }
        var waited = 0
        while release == nil, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertNotNil(release, "The Spark retry never started")

        // What a launch's sync does with an earlier failed send of the same invoice.
        Bitkit.LightningService.shared.releaseRailAttempt(paymentHash: hash)
        release?.resume()
        _ = try await retry.value
        rail.sentBolt11 = nil
        rail.listError = NSError(domain: "spark", code: 1)
        rail.balanceSats = 0

        await assertRefusedAsDuplicate()
    }

    func testASparkFailureReportedWhileItsSendIsInFlightStillReleasesTheHold() async throws {
        let hash = try String(Bolt11Invoice.fromStr(invoiceStr: Self.invoice).paymentHash())
        var release: CheckedContinuation<Void, Never>?
        rail.sendGate = { await withCheckedContinuation { release = $0 } }
        rail.balanceSats = 100_000
        let send = Task { try await Bitkit.LightningService.shared.send(bolt11: Self.invoice) }
        var waited = 0
        while release == nil, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertNotNil(release, "The Spark send never started")

        Bitkit.LightningService.shared.emitChannelFreeRailEvent(.paymentFailed(paymentId: hash, paymentHash: hash, reason: nil))
        release?.resume()
        _ = try await send.value
        rail.listError = NSError(domain: "spark", code: 1)
        rail.balanceSats = 0

        await assertReachesTheNode()
    }

    private func sendOverSpark() async throws {
        rail.balanceSats = 100_000
        _ = try await Bitkit.LightningService.shared.send(bolt11: Self.invoice)
        XCTAssertEqual(rail.sentBolt11, Self.invoice)
        rail.sentBolt11 = nil
    }

    private func assertRefusedAsDuplicate(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: Self.invoice)
            XCTFail("Expected the send to be refused as a duplicate", file: file, line: line)
        } catch {
            XCTAssertTrue(PrivatePaykitService.isDuplicatePaymentError(error), "\(error)", file: file, line: line)
        }
        XCTAssertNil(rail.sentBolt11, file: file, line: line)
    }

    /// Tests run without a node, so a payment that gets past the duplicate check fails as no node set up.
    private func assertReachesTheNode(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await Bitkit.LightningService.shared.send(bolt11: Self.invoice)
            XCTFail("Expected the send to reach the missing node", file: file, line: line)
        } catch {
            XCTAssertFalse(PrivatePaykitService.isDuplicatePaymentError(error), "\(error)", file: file, line: line)
            XCTAssertTrue("\(error)".contains("nodeNotSetup"), "\(error)", file: file, line: line)
        }
    }

    func testCanSendLeavesRoomForTheSparkFee() {
        rail.balanceSats = 100_000
        let sendable = Bitkit.ChannelFreeRailFees.sendableSats(balanceSats: 100_000)

        XCTAssertEqual(rail.sendableSats, sendable)
        XCTAssertTrue(Bitkit.LightningService.shared.canSend(amountSats: sendable))
        XCTAssertFalse(Bitkit.LightningService.shared.canSend(amountSats: 100_000))
    }

    func testAnAmountlessInvoiceNeedsSparkToHoldFunds() {
        rail.balanceSats = 0
        XCTAssertFalse(Bitkit.LightningService.shared.canSend(amountSats: 0), "An empty Spark wallet offered Spending for an amountless invoice")

        rail.balanceSats = 10000
        XCTAssertTrue(Bitkit.LightningService.shared.canSend(amountSats: 0))
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
        let service = Bitkit.LightningService.shared
        let nodePayments = service.nodePayments
        service.nodePayments = { [] }
        defer { service.nodePayments = nodePayments }

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

    func testTheSendSheetWaitsForTheChannelWhenSparkCanCoverOnlyTheAmountNotItsFee() {
        XCTAssertFalse(SendSheet.sparkCanPay(amountSats: 100_000, isReady: true, balanceSats: 100_000))
        XCTAssertTrue(SendSheet.sparkCanPay(amountSats: 99750, isReady: true, balanceSats: 100_000))
    }

    func testInsufficientFundsInsideTheSparkSendIsARefusal() {
        let failure = Bitkit.SparkManager.sendPaymentFailure(SdkError.InsufficientFunds(tokenIdentifier: nil))

        XCTAssertTrue(failure is Bitkit.ChannelFreeRailSendRefused, "\(failure)")
        XCTAssertFalse(Bitkit.SparkManager.sendPaymentFailure(SdkError.SparkError("operators")) is Bitkit.ChannelFreeRailSendRefused)
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

    func testAmountlessPaykitEndpointGoesToSparkBelowAMillionInbound() {
        XCTAssertTrue(Bitkit.LightningService.receivesOnRail(amountSats: nil, readyInboundSats: 50000, isPaykitEndpoint: true))
        XCTAssertTrue(Bitkit.LightningService.receivesOnRail(amountSats: nil, readyInboundSats: 999_999, isPaykitEndpoint: true))
        XCTAssertFalse(Bitkit.LightningService.receivesOnRail(amountSats: nil, readyInboundSats: 1_000_000, isPaykitEndpoint: true))
        XCTAssertTrue(Bitkit.LightningService.receivesOnRail(amountSats: nil, readyInboundSats: nil, isPaykitEndpoint: true))
    }

    func testPlainReceiveKeepsTheChannelWhileItHasInbound() {
        XCTAssertFalse(Bitkit.LightningService.receivesOnRail(amountSats: nil, readyInboundSats: 50000, isPaykitEndpoint: false))
        XCTAssertTrue(Bitkit.LightningService.receivesOnRail(amountSats: nil, readyInboundSats: 0, isPaykitEndpoint: false))
        XCTAssertTrue(Bitkit.LightningService.receivesOnRail(amountSats: nil, readyInboundSats: nil, isPaykitEndpoint: false))
        XCTAssertFalse(Bitkit.LightningService.receivesOnRail(amountSats: 40000, readyInboundSats: 50000, isPaykitEndpoint: false))
        XCTAssertTrue(Bitkit.LightningService.receivesOnRail(amountSats: 60000, readyInboundSats: 50000, isPaykitEndpoint: true))
    }

    func testAllowanceAutoPayGoesOverSparkWhenTheNodeCantPay() throws {
        let small = try PaykitAllowanceFixtures.paymentRequest(id: "550e8400-e29b-41d4-a716-446655440011", amount: "0.00001")
        let large = try PaykitAllowanceFixtures.paymentRequest(id: "550e8400-e29b-41d4-a716-446655440012", amount: "0.001")

        let nodeCanPay = PaykitAllowanceManager.payable([small, large], nodeCanPay: true, sparkSendableSats: nil)
        let sparkOnly = PaykitAllowanceManager.payable([small, large], nodeCanPay: false, sparkSendableSats: 5000)
        let neither = PaykitAllowanceManager.payable([small, large], nodeCanPay: false, sparkSendableSats: nil)

        XCTAssertEqual(nodeCanPay.map(\.id), [small.id, large.id])
        XCTAssertEqual(sparkOnly.map(\.id), [small.id], "Spark pays what it covers; the rest waits")
        XCTAssertTrue(neither.isEmpty)
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
    var sendGate: (() async -> Void)?
    var refusal: Bitkit.ChannelFreeRailSendRefused?
    var refusalAfterSubmission: Bitkit.ChannelFreeRailSendRefused?
    /// Runs while a listing is read, before it returns `payments`.
    var onList: (() -> Void)?

    func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String {
        "lnbcrt1fake"
    }

    func send(bolt11: String, sats: UInt64?, maxFeeSats: UInt64?, beforeSubmission: @escaping () throws -> Void) async throws -> PaymentHash {
        if let refusal {
            throw refusal
        }
        try beforeSubmission()
        if let refusalAfterSubmission {
            throw refusalAfterSubmission
        }
        await sendGate?()
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
        onList?()
        if let listError {
            throw listError
        }
        return payments
    }
}
