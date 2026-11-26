@testable import Bitkit
import XCTest

@MainActor
final class SpendingAmountHwTests: XCTestCase {
    private let walletId = "jade:wallet"
    private let depositAddress = "bcrt1qdeposit"
    private let todaysMaximum: UInt64 = 90000
    private let retainedSats: UInt64 = 95000

    private func retainedTransfer(retryWasRefused: Bool = false, observed: Bool = false) -> HwRetainedSend {
        HwRetainedSend(
            walletId: walletId,
            address: depositAddress,
            sats: retainedSats,
            serializedTx: "aabb",
            miningFeeSats: 141,
            feeRate: 2.5,
            totalSpent: retainedSats + 141,
            retryWasRefused: retryWasRefused,
            observed: observed
        )
    }

    private func quote(depositSats: UInt64) -> SparkTransferQuote {
        SparkTransferQuote(
            address: depositAddress,
            satsPerVbyte: 3,
            networkFeeSats: 141,
            depositSats: depositSats,
            claimFees: SparkClaimFees(instantMaxSats: 2000, laterSats: 500)
        )
    }

    private func retryLimits(_ record: HwRetainedSend) async throws -> (accepted: Bool, inputCap: UInt64?) {
        let service = HwRetainedSendService.inMemory()
        try await service.retain(record)
        let coordinator = HwSendCoordinator(walletId: walletId, retainedSends: service)
        let retrySats = await coordinator.retainedRetrySats(address: depositAddress, hasIncomingRequest: false)
        return (
            SendAmountView.isWithinSendableLimit(amountSats: retainedSats, availableSats: todaysMaximum, retainedRetrySats: retrySats),
            SendAmountView.amountInputCap(availableSats: todaysMaximum, retainedRetrySats: retrySats)
        )
    }

    func testRetainedTransferAboveTodaysMaximumStaysAccepted() async throws {
        let limits = try await retryLimits(retainedTransfer())

        XCTAssertTrue(limits.accepted)
        XCTAssertEqual(limits.inputCap, retainedSats)
    }

    func testRefusedRetryGetsTodaysMaximum() async throws {
        let limits = try await retryLimits(retainedTransfer(retryWasRefused: true))

        XCTAssertFalse(limits.accepted)
        XCTAssertEqual(limits.inputCap, todaysMaximum)
    }

    func testRepeatOfAnObservedTransferGetsTodaysMaximum() async throws {
        let limits = try await retryLimits(retainedTransfer(observed: true))

        XCTAssertFalse(limits.accepted)
        XCTAssertEqual(limits.inputCap, todaysMaximum)
    }

    func testFreshTransferBelowTheClaimFeeStays() {
        XCTAssertTrue(SpendingAmountHw.isBelowClaimFee(quote(depositSats: 1500), isRetainedRetry: false))
        XCTAssertFalse(SpendingAmountHw.isBelowClaimFee(quote(depositSats: 2500), isRetainedRetry: false))
    }

    func testRetainedRetryIsNotHeldUpByTodaysClaimFee() {
        XCTAssertFalse(SpendingAmountHw.isBelowClaimFee(quote(depositSats: 1500), isRetainedRetry: true))
    }
}
