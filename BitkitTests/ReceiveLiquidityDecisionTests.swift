@testable import Bitkit
import XCTest

final class ReceiveLiquidityDecisionTests: XCTestCase {
    func testPrimaryNodeCoversFixedAmountsWithoutChannels() {
        XCTAssertTrue(
            ReceiveLiquidityDecision.canCreateLightningInvoice(
                hasReadyChannels: false,
                inboundCapacitySats: nil,
                invoiceAmountSats: 5000,
                hasPrimaryNode: true
            )
        )

        XCTAssertFalse(
            ReceiveLiquidityDecision.canCreateLightningInvoice(
                hasReadyChannels: false,
                inboundCapacitySats: nil,
                invoiceAmountSats: nil,
                hasPrimaryNode: true
            )
        )
    }

    func testPrimaryNodeNeedsNoAdditionalLiquidityAction() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 1000,
                hasPrimaryNode: true
            ),
            .none
        )
    }

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

    func testZeroInboundKeepsTheQr() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(source: .spending, invoiceAmountSats: 10000, inboundCapacitySats: 0),
            .none
        )
    }

    func testAmountWithinInboundKeepsTheQr() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(source: .spending, invoiceAmountSats: 5000, inboundCapacitySats: 5000),
            .none
        )
    }

    func testOnlySpendingNeedsMoreCapacity() {
        for source in [ReceiveLiquiditySource.savings, .auto] {
            XCTAssertEqual(
                ReceiveLiquidityDecision.additionalLiquidityAction(source: source, invoiceAmountSats: 10000, inboundCapacitySats: 5000),
                .none
            )
        }
    }

    func testSpendingAmountOverInboundShowsTransferUnavailable() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(source: .spending, invoiceAmountSats: 10000, inboundCapacitySats: 5000),
            .transferUnavailable
        )
    }
}
