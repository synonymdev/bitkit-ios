import BitkitCore
import XCTest

@testable import Bitkit

final class SendSwapTests: XCTestCase {
    // MARK: - Inverse quote math

    func testQuoteGrossesFeesUpSoTheRecipientReceivesTheRequestedAmount() {
        let quote = SendSwapQuote.build(deliverSat: 100_000, limits: limits())

        XCTAssertEqual(quote.deliverSat, 100_000)
        XCTAssertEqual(quote.networkFeeSat, 320)
        XCTAssertEqual(quote.serviceFeeSat, quote.invoiceSat - 100_000)
        XCTAssertGreaterThan(quote.invoiceSat, 100_000)
        XCTAssertEqual(SendSwapQuote.delivered(invoiceSat: quote.invoiceSat, limits: limits()), 100_000)
    }

    func testQuoteIsTheSmallestInvoiceThatStillCoversTheRecipient() {
        let quote = SendSwapQuote.build(deliverSat: 100_000, limits: limits())

        // Boltz rounds its percentage fee up, so one sat less must fall short.
        XCTAssertLessThan(SendSwapQuote.delivered(invoiceSat: quote.invoiceSat - 1, limits: limits()), 100_000)
    }

    func testQuoteCoversTheRecipientAcrossARangeOfAmounts() {
        for deliverSat: UInt64 in [1000, 49999, 60000, 60001, 99999, 123_457, 1_000_000] {
            let quote = SendSwapQuote.build(deliverSat: deliverSat, limits: limits())
            XCTAssertGreaterThanOrEqual(
                SendSwapQuote.delivered(invoiceSat: quote.invoiceSat, limits: limits()),
                deliverSat,
                "recipient \(deliverSat) shorted by invoice \(quote.invoiceSat)"
            )
        }
    }

    func testQuoteCoversTheRecipientAcrossARangeOfFeeSchedules() {
        for feePercentage in [0.0, 0.1, 0.25, 0.5, 1.0, 5.0] {
            let schedule = limits(feePercentage: feePercentage)
            let quote = SendSwapQuote.build(deliverSat: 250_000, limits: schedule)
            XCTAssertGreaterThanOrEqual(
                SendSwapQuote.delivered(invoiceSat: quote.invoiceSat, limits: schedule),
                250_000,
                "recipient shorted at \(feePercentage)%"
            )
        }
    }

    func testQuoteChargesOnlyMinerFeesWithoutAPercentageFee() {
        let quote = SendSwapQuote.build(deliverSat: 100_000, limits: limits(feePercentage: 0))

        XCTAssertEqual(quote.invoiceSat, 100_320)
        XCTAssertEqual(quote.serviceFeeSat, 320)
    }

    func testQuoteInvertsTheForwardPricingTheSavingsSwapApplies() {
        // The transfer to savings prices an invoice down to an on-chain amount; a send starts
        // from the amount the recipient must receive, so the two must round-trip.
        let deliverSat = SendSwapQuote.delivered(invoiceSat: 500_000, limits: limits())
        let quote = SendSwapQuote.build(deliverSat: deliverSat, limits: limits())

        XCTAssertEqual(quote.invoiceSat, 500_000)
    }

    // MARK: - Bounds

    func testMaxDeliverableIsWhatTheSpendableBalanceDeliversAfterFees() {
        let sendableSat: UInt64 = 200_000

        let maxDeliverSat = SendSwapQuote.maxDeliverable(sendableSat: sendableSat, limits: limits())

        XCTAssertEqual(maxDeliverSat, SendSwapQuote.delivered(invoiceSat: sendableSat, limits: limits()))
        XCTAssertLessThan(maxDeliverSat, sendableSat)
    }

    func testMaxDeliverableIsCappedByTheSwapMaximum() {
        let maxDeliverSat = SendSwapQuote.maxDeliverable(sendableSat: 10_000_000, limits: limits())

        XCTAssertEqual(maxDeliverSat, SendSwapQuote.delivered(invoiceSat: 1_000_000, limits: limits()))
    }

    func testMaxDeliverableIsZeroWhenFeesExceedWhatCanBePaid() {
        XCTAssertEqual(SendSwapQuote.maxDeliverable(sendableSat: 100, limits: limits(minerFeesSat: 500)), 0)
    }

    func testQuoteMathToleratesADegenerateFeeSchedule() {
        // A non-finite percentage must not poison the UInt64 conversions downstream: it is coerced
        // to a zero rate, so only miner fees are charged and the recipient is still covered.
        let schedule = limits(feePercentage: .nan)
        let quote = SendSwapQuote.build(deliverSat: 100_000, limits: schedule)

        XCTAssertEqual(quote.invoiceSat, 100_320)
        XCTAssertGreaterThanOrEqual(SendSwapQuote.delivered(invoiceSat: quote.invoiceSat, limits: schedule), 100_000)
    }

    func testMinDeliverableQuotesToAtLeastTheSwapMinimum() {
        for schedule in [limits(), limits(feePercentage: 0.25, minerFeesSat: 320), limits(minimalSat: 50000)] {
            let minDeliverSat = SendSwapQuote.minDeliverable(limits: schedule)

            XCTAssertGreaterThanOrEqual(
                SendSwapQuote.build(deliverSat: minDeliverSat, limits: schedule).invoiceSat,
                schedule.minimalSat
            )
            XCTAssertLessThan(
                SendSwapQuote.build(deliverSat: minDeliverSat - 1, limits: schedule).invoiceSat,
                schedule.minimalSat
            )
        }
    }

    func testBoundsAreUnusableWhenTheBalanceCannotReachTheSwapMinimum() {
        let bounds = SendSwapBounds(
            minDeliverSat: SendSwapQuote.minDeliverable(limits: limits()),
            maxDeliverSat: SendSwapQuote.maxDeliverable(sendableSat: 10000, limits: limits())
        )

        XCTAssertFalse(bounds.isUsable)
    }

    func testBoundsAreUsableOnceTheBalanceClearsTheSwapMinimum() {
        let bounds = SendSwapBounds(
            minDeliverSat: SendSwapQuote.minDeliverable(limits: limits()),
            maxDeliverSat: SendSwapQuote.maxDeliverable(sendableSat: 500_000, limits: limits())
        )

        XCTAssertTrue(bounds.isUsable)
    }

    // MARK: - Availability

    @MainActor
    func testNoSwapIsOfferedWhileSwapsAreDisabled() async {
        // Unit tests run on regtest, where Boltz resolves to a local backend no build can reach,
        // so the send must fall back to the pre-swap insufficient-savings behaviour.
        XCTAssertFalse(BoltzService.shared.isSwapEnabled)

        let service = SendSwapService()

        let bounds = await service.bounds()
        let quote = await service.quote(deliverSat: 100_000)

        XCTAssertNil(bounds)
        XCTAssertNil(quote)
    }

    @MainActor
    func testZeroAmountIsNeverQuoted() async {
        let quote = await SendSwapService().quote(deliverSat: 0)

        XCTAssertNil(quote)
    }

    @MainActor
    func testSendStateResetClearsTheSwapSend() {
        let app = AppViewModel()
        app.isSwapSend = true
        app.sendSwapBounds = SendSwapBounds(minDeliverSat: 25000, maxDeliverSat: 100_000)
        app.sendSwapQuote = SendSwapQuote.build(deliverSat: 100_000, limits: limits())

        app.resetSendState()

        XCTAssertFalse(app.isSwapSend)
        XCTAssertNil(app.sendSwapBounds)
        XCTAssertNil(app.sendSwapQuote)
    }

    @MainActor
    func testFallingBackToSavingsKeepsBoundsSoTheSwapCanBeReArmed() async {
        // A swap send whose amount is lowered into savings range reverts to on-chain, but the
        // bounds must survive so raising the amount past savings again re-offers the swap without
        // a fresh scan (mirrors Android keeping swapMaxSendSats).
        let app = makeSwapSendApp()
        app.isSwapSend = true
        app.sendSwapBounds = SendSwapBounds(minDeliverSat: 25000, maxDeliverSat: 400_000)
        app.sendSwapQuote = SendSwapQuote.build(deliverSat: 100_000, limits: limits())

        await app.resolveSwapSendMethod(amountSats: 5000, onchainBalance: 10000)

        XCTAssertFalse(app.isSwapSend)
        XCTAssertNil(app.sendSwapQuote)
        XCTAssertEqual(app.sendSwapBounds?.maxDeliverSat, 400_000)
    }

    @MainActor
    func testSavingsCoversTheSendOnlyWhenItHoldsTheFullAmount() {
        let app = AppViewModel()

        XCTAssertTrue(app.hasSufficientOnchainBalance(invoiceAmount: 10000, onchainBalance: 10000))
        XCTAssertFalse(app.hasSufficientOnchainBalance(invoiceAmount: 10001, onchainBalance: 10000))
        // A zero-amount invoice only needs some balance; the amount screen validates the rest.
        XCTAssertTrue(app.hasSufficientOnchainBalance(invoiceAmount: 0, onchainBalance: 1))
        XCTAssertFalse(app.hasSufficientOnchainBalance(invoiceAmount: 0, onchainBalance: 0))
    }

    // MARK: - Fixtures

    @MainActor
    private func makeSwapSendApp() -> AppViewModel {
        let app = AppViewModel()
        app.scannedOnchainInvoice = OnChainInvoice(
            address: "bcrt1qswaprecipient",
            amountSatoshis: 0,
            label: nil,
            message: nil,
            params: nil
        )
        return app
    }

    private func limits(
        minimalSat: UInt64 = 25000,
        maximalSat: UInt64 = 1_000_000,
        feePercentage: Double = 0.5,
        minerFeesSat: UInt64 = 320
    ) -> BoltzPairInfo {
        BoltzPairInfo(
            hash: "hash",
            rate: 1.0,
            minimalSat: minimalSat,
            maximalSat: maximalSat,
            feePercentage: feePercentage,
            minerFeesSat: minerFeesSat
        )
    }
}
