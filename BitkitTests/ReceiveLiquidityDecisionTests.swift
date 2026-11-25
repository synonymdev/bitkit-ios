@testable import Bitkit
import XCTest

final class ReceiveLiquidityDecisionTests: XCTestCase {
    func testLightningInvoiceRequiresReadyChannel() {
        XCTAssertFalse(
            ReceiveLiquidityDecision.canCreateLightningInvoice(
                hasReadyChannels: false,
                inboundCapacitySats: 1000,
                invoiceAmountSats: nil
            )
        )
    }

    func testVariableLightningInvoiceRequiresNonZeroInboundLiquidity() {
        XCTAssertFalse(
            ReceiveLiquidityDecision.canCreateLightningInvoice(
                hasReadyChannels: true,
                inboundCapacitySats: 0,
                invoiceAmountSats: nil
            )
        )

        XCTAssertTrue(
            ReceiveLiquidityDecision.canCreateLightningInvoice(
                hasReadyChannels: true,
                inboundCapacitySats: 1,
                invoiceAmountSats: nil
            )
        )
    }

    func testFixedLightningInvoiceRequiresInboundLiquidityCoveringAmount() {
        XCTAssertTrue(
            ReceiveLiquidityDecision.canCreateLightningInvoice(
                hasReadyChannels: true,
                inboundCapacitySats: 5000,
                invoiceAmountSats: 5000
            )
        )

        XCTAssertFalse(
            ReceiveLiquidityDecision.canCreateLightningInvoice(
                hasReadyChannels: true,
                inboundCapacitySats: 4999,
                invoiceAmountSats: 5000
            )
        )
    }
}
