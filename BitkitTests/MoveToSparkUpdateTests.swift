@testable import Bitkit
import LDKNode
import XCTest

/// The rules of a Lightning payment that only the channels and Spark together cover: when it needs the spending balance
/// update, what the update must cover before it moves anything, and the update fee guard.
@MainActor
final class MoveToSparkUpdateTests: XCTestCase {
    private final class FakeServices: MoveToSparkServices, @unchecked Sendable {
        var isSparkUsable = true
        var spark = SparkSendState(isReady: true, isExiting: false, balanceSats: 30000)
        var sparkFee: () throws -> UInt64 = { 2 }

        func receiveInvoice(description _: String, expirySecs _: UInt32) async throws -> String {
            "lnbcrt1move"
        }

        func estimateChannelFee(bolt11 _: String, amountSats _: UInt64) async throws -> UInt64 {
            30
        }

        func estimateSparkFee(bolt11 _: String, amountSats _: UInt64) async throws -> UInt64 {
            try sparkFee()
        }

        func refreshSpark() async {}
    }

    private struct SparkCannotPrice: Error {}

    /// Channels that can send 32,000 sats, as in the Android journey's wallet.
    private let channels = [ChannelDetails.mock(outboundCapacityMsat: 32_000_000)]
    private let spark = SparkSendState(isReady: true, isExiting: false, balanceSats: 30000)

    func testAPaymentAboveBothRailsButWithinTheirSumNeedsTheUpdate() {
        let combined = MoveToSparkMath.combinedSendableSats(channels: channels, spark: spark)
        XCTAssertEqual(combined, ChannelFreeRailFees.sendableSats(balanceSats: 30000 + 32000 - 160 - 2))
        XCTAssertEqual(MoveToSparkMath.singleRailSendableSats(channels: channels, spark: spark), 32000)

        XCTAssertTrue(MoveToSparkMath.needsUpdateToSend(amountSats: 50000, channels: channels, spark: spark))
        XCTAssertFalse(
            MoveToSparkMath.needsUpdateToSend(amountSats: 32000, channels: channels, spark: spark),
            "A payment the channels cover alone was sent through an update"
        )
        XCTAssertFalse(MoveToSparkMath.needsUpdateToSend(amountSats: combined + 1, channels: channels, spark: spark))
        XCTAssertEqual(MoveToSparkMath.maxSendSats(channels: channels, spark: spark), combined)
    }

    func testASwapSpendsOnlyWhatOneRailSends() {
        let maxSendSats = MoveToSparkMath.maxSendSats(channels: channels, spark: spark)
        XCTAssertEqual(MoveToSparkMath.swapSpendableSats(maxSendSats: maxSendSats, channels: channels, spark: spark), 32000)
        XCTAssertEqual(MoveToSparkMath.swapSpendableSats(maxSendSats: 10000, channels: channels, spark: spark), 10000)
    }

    func testNoUpdateWhileSparkTakesNoMove() {
        let exiting = SparkSendState(isReady: true, isExiting: true, balanceSats: 30000)
        XCTAssertEqual(MoveToSparkMath.combinedSendableSats(channels: channels, spark: exiting), 0)
        XCTAssertFalse(MoveToSparkMath.needsUpdateToSend(amountSats: 50000, channels: channels, spark: exiting))
        XCTAssertEqual(MoveToSparkMath.singleRailSendableSats(channels: channels, spark: exiting), 32000)
        XCTAssertEqual(MoveToSparkMath.combinedSendableSats(channels: [], spark: spark), 0)
    }

    func testTheUpdateMustCoverThePaymentAndSparksFee() {
        let quote = MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 20000, feeSats: 32)
        XCTAssertTrue(MoveToSparkMath.coversPayment(quote: quote, spark: spark, amountSats: 49998, feeSats: 2))
        XCTAssertFalse(MoveToSparkMath.coversPayment(quote: quote, spark: spark, amountSats: 49999, feeSats: 2))
        let notReady = SparkSendState(isReady: false, isExiting: false, balanceSats: 30000)
        XCTAssertFalse(MoveToSparkMath.coversPayment(quote: quote, spark: notReady, amountSats: 1000, feeSats: 2))
    }

    func testTheUpdateFeeGuardStopsAFeeNotShownOrAboveTheOneShown() {
        XCTAssertTrue(MoveToSparkMath.isUpdateFeeUnseen(shownFeeSats: nil, freshFeeSats: 2), "An update fee nobody saw was charged")
        XCTAssertTrue(MoveToSparkMath.isUpdateFeeUnseen(shownFeeSats: 2, freshFeeSats: 3), "A risen update fee was charged unseen")
        XCTAssertFalse(MoveToSparkMath.isUpdateFeeUnseen(shownFeeSats: 2, freshFeeSats: 2))
        XCTAssertFalse(MoveToSparkMath.isUpdateFeeUnseen(shownFeeSats: 3, freshFeeSats: 2))
    }

    func testAnUpdateThatFallsShortMovesNothing() async {
        let services = FakeServices()
        let manager = MoveToSparkManager(services: services)
        let quote = MoveToSparkQuote(invoice: "lnbcrt1move", amountSats: 20000, feeSats: 32)

        await assertNoThrow { try await manager.checkCoverage(quote: quote, bolt11: "lnbcrt1pay", amountSats: 49998) }
        await assertFallsShort { try await manager.checkCoverage(quote: quote, bolt11: "lnbcrt1pay", amountSats: 49999) }

        services.sparkFee = { throw SparkCannotPrice() }
        await assertFallsShort { try await manager.checkCoverage(quote: quote, bolt11: "lnbcrt1pay", amountSats: 1000) }
    }

    func testAnLnurlBeforeItsInvoiceIsPricedWithSparksServiceFee() async {
        let services = FakeServices()
        services.sparkFee = { 7 }
        let manager = MoveToSparkManager(services: services)
        let lnurlFee = await manager.estimateFeeAfterUpdate(bolt11: nil, amountSats: 50000)
        XCTAssertEqual(lnurlFee, ChannelFreeRailFees.serviceFeeSats(amountSats: 50000))
        XCTAssertEqual(ChannelFreeRailFees.serviceFeeSats(amountSats: 50000), 125)
        XCTAssertEqual(ChannelFreeRailFees.serviceFeeSats(amountSats: 1), 1)
        let invoiceFee = await manager.estimateFeeAfterUpdate(bolt11: "lnbcrt1pay", amountSats: 50000)
        XCTAssertEqual(invoiceFee, 7)
    }

    func testTheSwipeWaitsForTheUpdateQuote() {
        XCTAssertTrue(SendConfirmationView.isSwipeDisabled(
            walletType: .lightning,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 1,
            isUpdateQuoting: true
        ))
        XCTAssertFalse(SendConfirmationView.isSwipeDisabled(
            walletType: .lightning,
            isHardwarePayment: false,
            isHardwareConfirmationUnavailable: false,
            feeRate: 1
        ))
    }

    func testAnEstimateWithoutTheUpdateSupersedesAQuoteStillLoading() {
        var runs = SparkUpdateQuoteRuns()
        let older = runs.start()
        XCTAssertTrue(runs.isQuoting)
        runs.invalidate()
        XCTAssertFalse(runs.isCurrent(older))
        XCTAssertFalse(runs.isQuoting)
        runs.finish(older)
        XCTAssertFalse(runs.isQuoting)
    }

    func testOnlyTheNewestUpdateQuoteHoldsTheSwipe() {
        var runs = SparkUpdateQuoteRuns()
        let older = runs.start()
        let newer = runs.start()
        runs.finish(older)
        XCTAssertTrue(runs.isQuoting)
        XCTAssertFalse(runs.isCurrent(older))
        XCTAssertTrue(runs.isCurrent(newer))
        runs.finish(newer)
        XCTAssertFalse(runs.isQuoting)
    }

    func testSwapRoutesAndSparkLegsNeverNeedTheUpdate() {
        func sats(_ walletType: WalletType, leg: Bool = false, swap: Bool = false, invoice: UInt64 = 0) -> UInt64? {
            SendConfirmationView.sparkUpdatePaymentSats(
                walletType: walletType, hasServiceLeg: leg, hasSwapRoute: swap, invoiceAmountSats: invoice, sendAmountSats: 40000
            )
        }
        XCTAssertEqual(sats(.lightning), 40000)
        XCTAssertEqual(sats(.lightning, invoice: 25000), 25000)
        XCTAssertNil(sats(.lightning, swap: true))
        XCTAssertNil(sats(.lightning, leg: true))
        XCTAssertNil(sats(.onchain))
    }

    private func assertFallsShort(_ operation: () async throws -> Void, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("An update that falls short went ahead", line: line)
        } catch {
            guard case .updateFallsShort = error as? MoveToSparkError else {
                return XCTFail("Unexpected error \(error)", line: line)
            }
        }
    }

    private func assertNoThrow(_ operation: () async throws -> Void, line: UInt = #line) async {
        do {
            try await operation()
        } catch {
            XCTFail("Unexpected error \(error)", line: line)
        }
    }
}
