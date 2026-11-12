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

    /// Every deposit state shows one frame of the Funds In Transfer (spark) design, at the step that frame shows.
    func testSettingUpShowsTheDesignFrameForEveryState() {
        let expected: [(SparkClaimState, SparkTransferSpeed, SettingUpStage, Int)] = [
            (.looking, .instant, .processing(normalSpeed: false), 0),
            (.later, .later, .processing(normalSpeed: true), 0),
            (.notSeen, .instant, .processing(normalSpeed: true), 0),
            (.claiming, .instant, .received, 1),
            (.repriced(feeSats: 2134), .instant, .feeChanged(feeSats: 2134), 2),
            (.unavailable, .instant, .fastUnavailable, 2),
            (.later, .instant, .adding(normalSpeed: true), 2),
            (.adding, .instant, .adding(normalSpeed: false), 2),
            (.added, .instant, .done, 2),
        ]
        for (state, speed, stage, step) in expected {
            let shown = SettingUpStage(state: state, speed: speed)
            XCTAssertEqual(shown, stage, "\(state) at \(speed)")
            XCTAssertEqual(shown.currentStep, step, "\(state) at \(speed)")
            XCTAssertEqual(shown.steps.count, 3, "\(state) shows three steps")
        }
    }

    func testApprovingAChangedFeeNeverStepsBackToPaymentSuccessful() {
        XCTAssertEqual(SettingUpStage(state: .claiming, speed: .instant, approvedFee: true), .adding(normalSpeed: false))
    }

    func testSettingUpSaysAboutThirtyMinutesOnlyAtNormalSpeed() {
        let normal: [SettingUpStage] = [.processing(normalSpeed: true), .fastUnavailable, .adding(normalSpeed: true)]
        let fast: [SettingUpStage] = [.processing(normalSpeed: false), .received, .adding(normalSpeed: false)]
        normal.forEach { XCTAssertTrue($0.isNormalSpeed, "\($0)") }
        fast.forEach { XCTAssertFalse($0.isNormalSpeed, "\($0)") }
    }

    func testSettingUpLabelsTheLastStepByWhatItIsDoing() {
        XCTAssertEqual(SettingUpStage.feeChanged(feeSats: 1).steps.last, t("lightning__setting_up__step_fee_changed"))
        XCTAssertEqual(SettingUpStage.fastUnavailable.steps.last, t("lightning__setting_up__step_normal_speed"))
        XCTAssertEqual(SettingUpStage.adding(normalSpeed: true).steps.last, t("lightning__setting_up__step_normal_speed"))
        XCTAssertEqual(SettingUpStage.adding(normalSpeed: false).steps.last, t("lightning__setting_up_step_spark"))
    }
}
