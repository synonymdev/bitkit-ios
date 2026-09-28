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

    func testZeroInboundDoesNotRouteToCjit() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 0,
                minCjitSats: 5000,
                maxCjitAmountSats: 100_000,
                isGeoBlocked: false
            ),
            .none
        )
    }

    func testSavingsAndAutoEditsDoNotRouteToCjit() {
        for source in [ReceiveLiquiditySource.savings, .auto] {
            XCTAssertEqual(
                ReceiveLiquidityDecision.additionalLiquidityAction(
                    source: source,
                    invoiceAmountSats: 10000,
                    inboundCapacitySats: 1000,
                    minCjitSats: 5000,
                    maxCjitAmountSats: 100_000,
                    isGeoBlocked: false
                ),
                .none
            )
        }
    }

    func testBelowCjitMinimumRoutesToAmountPicker() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 4000,
                inboundCapacitySats: 1000,
                minCjitSats: 5000,
                maxCjitAmountSats: 100_000,
                isGeoBlocked: false
            ),
            .chooseAmount
        )
    }

    func testAtCjitMinimumCreatesCjit() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 5000,
                inboundCapacitySats: 1000,
                minCjitSats: 5000,
                maxCjitAmountSats: 100_000,
                isGeoBlocked: false
            ),
            .createCjit(5000)
        )
    }

    func testOverMaxCjitAmountRoutesToAmountPicker() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 100_001,
                inboundCapacitySats: 1000,
                minCjitSats: 5000,
                maxCjitAmountSats: 100_000,
                isGeoBlocked: false
            ),
            .chooseAmount
        )
    }

    func testUnknownMaxCjitAmountRoutesToAmountPicker() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 1000,
                minCjitSats: 5000,
                maxCjitAmountSats: nil,
                isGeoBlocked: false
            ),
            .chooseAmount
        )
    }

    func testGeoBlockedRoutesToGeoBlock() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 1000,
                minCjitSats: 5000,
                maxCjitAmountSats: 100_000,
                isGeoBlocked: true
            ),
            .geoBlocked
        )
    }

    func testNoAdditionalLiquidityNeededReturnsNone() {
        XCTAssertEqual(
            ReceiveLiquidityDecision.additionalLiquidityAction(
                source: .spending,
                invoiceAmountSats: 1000,
                inboundCapacitySats: 1000,
                minCjitSats: 5000,
                maxCjitAmountSats: 100_000,
                isGeoBlocked: false
            ),
            .none
        )
    }

    func testCjitLimitsAreFetchedOnlyWhenAdditionalLiquidityCanUseThem() {
        XCTAssertFalse(
            ReceiveLiquidityDecision.needsCjitLimitsForAdditionalLiquidity(
                source: .auto,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 1000,
                isGeoBlocked: false
            )
        )

        XCTAssertFalse(
            ReceiveLiquidityDecision.needsCjitLimitsForAdditionalLiquidity(
                source: .spending,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 0,
                isGeoBlocked: false
            )
        )

        XCTAssertFalse(
            ReceiveLiquidityDecision.needsCjitLimitsForAdditionalLiquidity(
                source: .spending,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 1000,
                isGeoBlocked: true
            )
        )

        XCTAssertTrue(
            ReceiveLiquidityDecision.needsCjitLimitsForAdditionalLiquidity(
                source: .spending,
                invoiceAmountSats: 10000,
                inboundCapacitySats: 1000,
                isGeoBlocked: false
            )
        )
    }
}
