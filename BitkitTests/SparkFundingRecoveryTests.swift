@testable import Bitkit
import XCTest

/// A Spark funding whose outcome was unknown, resolved from the Send sheet's pending screen.
@MainActor
final class SparkFundingRecoveryTests: XCTestCase {
    private let walletId = OnchainSendAttemptService.walletId(index: 0)

    private func resolvedSend(isSparkFunding: Bool, txid: String) async throws -> OnchainSendLocalResolution {
        let service = OnchainSendAttemptService(store: MemoryAttemptStore())
        let id = try await service.admit(
            walletId: walletId, requestId: nil, orderId: nil, address: "bcrt1qspark-deposit", amountSats: 30000, isMaxAmount: false,
            followupContext: OnchainSendFollowupContext(feeSats: 200, feeRate: 2, tags: [], contact: nil, createdAt: 100),
            isSparkFunding: isSparkFunding
        )
        try await service.record(.accepted(txid: txid), attemptId: id)
        let resolution = try await service.resumeAcceptedOrdinarySend(walletId: walletId)
        return try XCTUnwrap(resolution)
    }

    func testARecoveredSparkFundingIsHandedToSparkAndLeavesTheFundingFlow() async throws {
        let txid = String(repeating: "5a", count: 32)
        let resolution = try await resolvedSend(isSparkFunding: true, txid: txid)
        var handedOff: [(String, UInt64)] = []

        let leaves = await SparkFundingRecovery.follow(resolution) { handedOff.append(($0, $1)) }

        XCTAssertTrue(resolution.isSparkFunding)
        XCTAssertTrue(leaves, "The old confirm screen would offer the sent transfer again")
        XCTAssertEqual(handedOff.map(\.0), [txid])
        XCTAssertEqual(handedOff.map(\.1), [30000])
    }

    func testARecoveredOrdinarySendIsNotHandedToSpark() async throws {
        let resolution = try await resolvedSend(isSparkFunding: false, txid: String(repeating: "6b", count: 32))
        var handedOff = 0

        let leaves = await SparkFundingRecovery.follow(resolution) { _, _ in handedOff += 1 }

        XCTAssertFalse(resolution.isSparkFunding)
        XCTAssertFalse(leaves)
        XCTAssertEqual(handedOff, 0)
    }

    func testSpendingConfirmFollowsItsFundingOnceItResolvesOnItsOwn() async throws {
        let spark = try await resolvedSend(isSparkFunding: true, txid: String(repeating: "7c", count: 32))
        let ordinary = try await resolvedSend(isSparkFunding: false, txid: String(repeating: "8d", count: 32))

        XCTAssertTrue(SpendingConfirm.followsRecovered(spark, isPaying: false))
        XCTAssertFalse(SpendingConfirm.followsRecovered(spark, isPaying: true), "The swipe's own funding goes on to Setting Up")
        XCTAssertFalse(SpendingConfirm.followsRecovered(ordinary, isPaying: false))
    }

    func testAnOpenSpendingConfirmOwnsTheRecoveredFunding() {
        XCTAssertFalse(SparkFundingRecovery.pendingScreenGoesHome(confirmScreenOpen: true), "Spending Confirm follows it at the chosen speed")
        XCTAssertTrue(SparkFundingRecovery.pendingScreenGoesHome(confirmScreenOpen: false))
    }

    func testSettingUpShowsLaterWheneverTheTextSaysItWaitsForConfirmations() {
        for state in [SparkClaimState.later, .unavailable, .notSeen] {
            XCTAssertTrue(SettingUpView.showsLater(speed: .instant, state: state), "\(state)")
        }
        for state in [SparkClaimState.looking, .claiming, .adding, .added, .repriced(feeSats: 1)] {
            XCTAssertFalse(SettingUpView.showsLater(speed: .instant, state: state), "\(state)")
        }
        XCTAssertTrue(SettingUpView.showsLater(speed: .later, state: .looking))
    }

    func testSettingUpShowsAStepForEveryStateStillInProgress() {
        let states: [SparkClaimState] = [.looking, .claiming, .adding, .repriced(feeSats: 1), .unavailable, .later, .notSeen]
        for state in states {
            XCTAssertFalse(state.isDone, "\(state)")
            XCTAssertLessThan(SettingUpView.currentStep(for: state), 3, "\(state) points past the last step")
        }
        XCTAssertEqual(SettingUpView.currentStep(for: .adding), 2, "Adding is the last step, Spark adding it")
    }

    /// The same step as Android's `SettingUpScreen` for every state: a deposit Spark has not seen stays on
    /// Payment Successful, whatever the speed.
    func testSettingUpStepMatchesAndroidForEveryState() {
        let expected: [(SparkClaimState, Int)] = [
            (.looking, 1),
            (.notSeen, 1),
            (.later, 1),
            (.claiming, 2),
            (.adding, 2),
            (.repriced(feeSats: 1), 2),
            (.unavailable, 2),
            (.added, 3),
        ]
        for (state, step) in expected {
            XCTAssertEqual(SettingUpView.currentStep(for: state), step, "\(state)")
        }
    }
}
