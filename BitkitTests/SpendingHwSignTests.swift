@testable import Bitkit
import XCTest

@MainActor
final class SpendingHwSignTests: XCTestCase {
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
