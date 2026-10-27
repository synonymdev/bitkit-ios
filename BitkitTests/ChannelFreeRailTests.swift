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

    func testPrivatePaykitSeesRailReceivesAndSends() async {
        rail.payments = [
            Bitkit.ChannelFreeRailPayment(paymentHash: "in", direction: .inbound, status: .succeeded, preimage: nil),
            Bitkit.ChannelFreeRailPayment(paymentHash: "out", direction: .outbound, status: .pending, preimage: nil),
            Bitkit.ChannelFreeRailPayment(paymentHash: "failed", direction: .outbound, status: .failed, preimage: nil),
        ]

        let received = await PrivatePaykitService.shared.receivedSettledPaymentHashes()
        let attempted = await PrivatePaykitService.shared.attemptedOutboundBolt11PaymentHashes()

        XCTAssertTrue(received.contains("in"))
        XCTAssertEqual(attempted.intersection(["out", "failed"]), ["out"])
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
            XCTAssertNil(rail.sentBolt11)
        }

        let roomy = RouteParametersConfig(
            maxTotalRoutingFeeMsat: 10000, maxTotalCltvExpiryDelta: 1008, maxPathCount: 10, maxChannelSaturationPowerOfHalf: 2
        )
        _ = try await Bitkit.LightningService.shared.send(bolt11: "lnbcrt1rail", sats: 100, params: roomy)
        XCTAssertEqual(rail.sentBolt11, "lnbcrt1rail")
    }
}

private final class FakeRail: Bitkit.ChannelFreeLightningRail {
    var isReady = true
    var balanceSats: UInt64 = 9572
    var payments: [Bitkit.ChannelFreeRailPayment] = []
    var routingFeeSats: UInt64 = 0
    var sentBolt11: String?

    func receive(amountSats: UInt64?, description: String, expirySecs: UInt32) async throws -> String {
        "lnbcrt1fake"
    }

    func send(bolt11: String, sats: UInt64?) async throws -> PaymentHash {
        sentBolt11 = bolt11
        return "ee"
    }

    func estimateRoutingFees(bolt11: String, amountSats: UInt64?) async throws -> UInt64 {
        routingFeeSats
    }

    func lightningPayments() async -> [Bitkit.ChannelFreeRailPayment] {
        payments
    }
}
