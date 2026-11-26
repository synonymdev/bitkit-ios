@testable import Bitkit
import XCTest

@MainActor
final class SpendingHwSignTests: XCTestCase {
    private var store = SparkSentDeposits()

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try SparkSentDeposits(defaults: makeIsolatedDefaults())
    }

    private let walletId = "jade:wallet"
    private let depositAddress = "bcrt1qdeposit"
    private let signedTx = HwFundingSignedTx(serializedTx: "aabb", miningFeeSats: 141, feeRate: 2.5, totalSpent: 42141)

    private func retainedTransfer(sats: UInt64 = 42000, observed: Bool = false) -> HwRetainedSend {
        HwRetainedSend(
            walletId: walletId,
            address: depositAddress,
            sats: sats,
            serializedTx: signedTx.serializedTx,
            miningFeeSats: signedTx.miningFeeSats,
            feeRate: signedTx.feeRate,
            totalSpent: signedTx.totalSpent,
            observed: observed
        )
    }

    private func signingStep(_ coordinator: HwSendCoordinator, sats: UInt64) async -> SpendingHwSign.SigningStep {
        let status = await coordinator.retainedSendStatus(address: depositAddress, sats: sats, hasIncomingRequest: false)
        return SpendingHwSign.signingStep(retainedStatus: status, isRetryOnThisScreen: false)
    }

    func testBlockingStatusWarnsInsteadOfSigning() {
        XCTAssertEqual(SpendingHwSign.signingStep(retainedStatus: .blocking, isRetryOnThisScreen: false), .confirmNewSignature)
    }

    func testRetryStatusSignsWithoutWarning() {
        XCTAssertEqual(SpendingHwSign.signingStep(retainedStatus: .retry(signedTx), isRetryOnThisScreen: false), .sign)
    }

    func testNoRetainedSendSigns() {
        XCTAssertEqual(SpendingHwSign.signingStep(retainedStatus: .none, isRetryOnThisScreen: false), .sign)
    }

    func testRetryOnThisScreenRebroadcastsWithoutWarning() {
        XCTAssertEqual(SpendingHwSign.signingStep(retainedStatus: .blocking, isRetryOnThisScreen: true), .sign)
    }

    func testAnotherAmountOverAnUnobservedTransferWarnsThenSignsAfterConsent() async throws {
        let service = HwRetainedSendService.inMemory()
        try await service.retain(retainedTransfer())
        let coordinator = HwSendCoordinator(walletId: walletId, retainedSends: service)

        let warned = await signingStep(coordinator, sats: 50000)
        XCTAssertEqual(warned, .confirmNewSignature)

        coordinator.consentToNewSignature(address: depositAddress, sats: 50000)

        let consented = await signingStep(coordinator, sats: 50000)
        XCTAssertEqual(consented, .sign)
        let record = try await service.record(walletId: walletId)
        XCTAssertEqual(record, retainedTransfer())
    }

    func testNewTransferAfterConsentWarnsAgain() async throws {
        let service = HwRetainedSendService.inMemory()
        try await service.retain(retainedTransfer())
        let coordinator = HwSendCoordinator(walletId: walletId, retainedSends: service)
        coordinator.consentToNewSignature(address: depositAddress, sats: 50000)

        coordinator.selectWallet(walletId, initialAvailableSats: 0, showsLoading: true)
        coordinator.endRetainedSendConsent()

        let step = await signingStep(coordinator, sats: 50000)
        XCTAssertEqual(step, .confirmNewSignature)
    }

    func testRepeatOfAnObservedTransferWarnsBeforeSigning() async throws {
        let service = HwRetainedSendService.inMemory()
        try await service.retain(retainedTransfer(observed: true))
        let coordinator = HwSendCoordinator(walletId: walletId, retainedSends: service)

        let step = await signingStep(coordinator, sats: 42000)

        XCTAssertEqual(step, .confirmNewSignature)
    }

    func testRetryOfTheSameUnobservedTransferSignsWithoutWarning() async throws {
        let service = HwRetainedSendService.inMemory()
        try await service.retain(retainedTransfer())
        let coordinator = HwSendCoordinator(walletId: walletId, retainedSends: service)

        let status = await coordinator.retainedSendStatus(address: depositAddress, sats: 42000, hasIncomingRequest: false)

        XCTAssertEqual(status, .retry(signedTx))
        XCTAssertEqual(SpendingHwSign.signingStep(retainedStatus: status, isRetryOnThisScreen: false), .sign)
    }

    func testRetainedRetryQuoteKeepsTheOriginalFee() {
        let claimFees = SparkClaimFees(instantMaxSats: 2000, laterSats: 500)

        let quote = SpendingHwSign.retainedRetryQuote(address: depositAddress, depositSats: 42000, signedTx: signedTx, claimFees: claimFees)

        XCTAssertEqual(quote, SparkTransferQuote(
            address: depositAddress,
            satsPerVbyte: 3,
            networkFeeSats: signedTx.miningFeeSats,
            depositSats: 42000,
            claimFees: claimFees
        ))
    }

    /// A retained Retry of the flow's amount whose claim fee waits until `claimFeeGate` opens, returned once it is waiting on it.
    private func delayedRetainedRetry(
        _ flow: SparkTransferFlow,
        claimFeeGate: AsyncGate
    ) async -> Task<SparkRetainedRetryPricing, Never> {
        let depositAddress = depositAddress
        let waitingOnClaimFee = AsyncGate()
        let retry = Task {
            await flow.refreshRetainedRetryQuote(depositAddress: { depositAddress }, claimFees: { _ in
                waitingOnClaimFee.open()
                await claimFeeGate.wait()
                return SparkClaimFees(instantMaxSats: 2000, laterSats: 500)
            })
        }
        await waitingOnClaimFee.wait()
        return retry
    }

    private func hwFlow(retaining record: HwRetainedSend, operations: SparkClaimOperations = .live) async throws -> SparkTransferFlow {
        let service = HwRetainedSendService.inMemory()
        try await service.retain(record)
        let flow = SparkTransferFlow(
            operations: operations,
            pollAttempts: 2,
            hwSend: HwSendCoordinator(walletId: walletId, retainedSends: service),
            sentDeposits: store
        )
        flow.start(amountSats: record.sats, isMaxAmount: false, walletId: walletId)
        return flow
    }

    func testADelayedRetainedRetryQuoteNeverReplacesALaterTransfersQuote() async throws {
        let flow = try await hwFlow(retaining: retainedTransfer(sats: 42000))
        let claimFeeGate = AsyncGate()
        let delayedRetry = await delayedRetainedRetry(flow, claimFeeGate: claimFeeGate)

        flow.start(amountSats: 50000, isMaxAmount: false, walletId: walletId)
        let later = await flow.refreshRetainedRetryQuote(depositAddress: { self.depositAddress }, claimFees: { _ in
            XCTFail("Another amount was priced as a Retry")
            return SparkClaimFees(instantMaxSats: 2000, laterSats: 500)
        })
        XCTAssertEqual(later, .priceAnew)
        // Stands in for the fresh quote `refreshQuote` writes next, which needs the live Spark SDK.
        let laterQuote = SparkTransferQuote(
            address: depositAddress,
            satsPerVbyte: 4,
            networkFeeSats: 300,
            depositSats: 50000,
            claimFees: SparkClaimFees(instantMaxSats: 2000, laterSats: 500)
        )
        flow.quote = laterQuote
        claimFeeGate.open()

        let stale = await delayedRetry.value
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(flow.quote, laterQuote, "The earlier transfer's quote replaced the later one")
        XCTAssertNil(flow.quoteError)
    }

    func testALaterRetainedRetryQuoteSupersedesADelayedOne() async throws {
        let flow = try await hwFlow(retaining: retainedTransfer(sats: 42000))
        let claimFeeGate = AsyncGate()
        let delayedRetry = await delayedRetainedRetry(flow, claimFeeGate: claimFeeGate)

        let laterFees = SparkClaimFees(instantMaxSats: 2100, laterSats: 600)
        let later = await flow.refreshRetainedRetryQuote(depositAddress: { self.depositAddress }, claimFees: { _ in laterFees })
        let laterQuote = SpendingHwSign.retainedRetryQuote(address: depositAddress, depositSats: 42000, signedTx: signedTx, claimFees: laterFees)
        XCTAssertEqual(later, .retry(laterQuote))
        XCTAssertFalse(flow.isQuoting)
        claimFeeGate.open()

        let stale = await delayedRetry.value
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(flow.quote, laterQuote)
        XCTAssertFalse(flow.isQuoting)
    }

    func testARetainedRetryKeepsTheSignedClaimFeeWhenARefreshRepricesItDuringTheBroadcast() async throws {
        let operations = SparkClaimOperations(
            offer: { txid in
                SparkClaimOffer(
                    txid: txid,
                    vout: 0,
                    kind: .choice(earlyFeeSats: 1500, earlyConfirmations: 0, standardFeeSats: 198, standardConfirmations: 3)
                )
            },
            claimEarly: { _, _ in
                XCTFail("Claimed early above the signed claim fee")
                return .claimed
            },
            isUnclaimed: { _ in true },
            refresh: {},
            sleep: { _ in }
        )
        let flow = try await hwFlow(retaining: retainedTransfer(sats: 42000), operations: operations)
        let accepted = try XCTUnwrap(SpendingHwSign.retainedRetryQuote(
            address: depositAddress,
            depositSats: 42000,
            signedTx: signedTx,
            claimFees: SparkClaimFees(instantMaxSats: 1000, laterSats: 500)
        ))
        flow.quote = accepted
        let claimFeeGate = AsyncGate()
        let refresh = await delayedRetainedRetry(flow, claimFeeGate: claimFeeGate)

        // The refresh reprices the claim fee to 2,000 sats after Retry signed the accepted quote, while its broadcast waits.
        claimFeeGate.open()
        _ = await refresh.value
        XCTAssertEqual(flow.quote?.claimFees.instantMaxSats, 2000)
        SpendingHwSign.startClaim(flow: flow, txid: "txid", signed: accepted)
        await flow.waitForClaim()

        XCTAssertEqual(flow.claimState, .repriced(feeSats: 1500))
    }

    func testRetainedRetryPricingIsBusyDuringItsLookups() async throws {
        let flow = try await hwFlow(retaining: retainedTransfer(sats: 42000))
        let depositAddress = depositAddress
        let waitingOnAddress = AsyncGate()
        let addressGate = AsyncGate()
        let retry = Task {
            await flow.refreshRetainedRetryQuote(depositAddress: {
                waitingOnAddress.open()
                await addressGate.wait()
                return depositAddress
            }, claimFees: { _ in SparkClaimFees(instantMaxSats: 1000, laterSats: 500) })
        }
        await waitingOnAddress.wait()

        XCTAssertTrue(flow.isQuoting, "Retry stayed enabled while the retained transfer was looked up")
        addressGate.open()
        guard case .retry = await retry.value else { return XCTFail("Not priced as a Retry") }
        XCTAssertFalse(flow.isQuoting)
    }

    func testRetainedRetryPricingThatPricesAnewIsNotLeftBusy() async throws {
        let flow = try await hwFlow(retaining: retainedTransfer(sats: 42000))
        flow.start(amountSats: 50000, isMaxAmount: false, walletId: walletId)

        let pricing = await flow.refreshRetainedRetryQuote(depositAddress: { self.depositAddress }, claimFees: { _ in
            XCTFail("Another amount was priced as a Retry")
            return SparkClaimFees(instantMaxSats: 1000, laterSats: 500)
        })

        XCTAssertEqual(pricing, .priceAnew)
        XCTAssertFalse(flow.isQuoting)
    }

    func testRetainedRetryQuoteNeedsAFeeRateItCanShow() {
        let unshowable = HwFundingSignedTx(serializedTx: "aabb", miningFeeSats: 141, feeRate: .nan, totalSpent: 42141)

        XCTAssertNil(SpendingHwSign.retainedRetryQuote(
            address: depositAddress,
            depositSats: 42000,
            signedTx: unshowable,
            claimFees: SparkClaimFees(instantMaxSats: 2000, laterSats: 500)
        ))
    }
}
