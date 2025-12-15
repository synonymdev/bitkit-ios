// AutoPayViewModelTests.swift
// BitkitTests
//
// Unit tests for AutoPayViewModel

import XCTest
@testable import Bitkit

final class AutoPayViewModelTests: XCTestCase {

    var viewModel: AutoPayViewModel!

    override func setUp() {
        super.setUp()
        viewModel = AutoPayViewModel()
        // Clear any existing settings
        viewModel.resetSettings()
    }

    override func tearDown() {
        viewModel.resetSettings()
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Settings Tests

    func testDefaultSettingsAreDisabled() {
        // When
        let settings = viewModel.settings

        // Then
        XCTAssertFalse(settings.globalEnabled)
    }

    func testSaveAndLoadSettings() async {
        // Given
        let settings = AutoPaySettings(
            globalEnabled: true,
            globalMaxAmount: 10000,
            globalDailyLimit: 50000,
            requireConfirmationAbove: 5000,
            rules: []
        )

        // When
        await viewModel.saveSettings(settings)
        await viewModel.loadSettings()

        // Then
        XCTAssertTrue(viewModel.settings.globalEnabled)
        XCTAssertEqual(viewModel.settings.globalMaxAmount, 10000)
    }

    // MARK: - Evaluation Tests

    func testEvaluateRequiresApprovalWhenDisabled() async {
        // Given
        viewModel.settings = AutoPaySettings(globalEnabled: false)
        let request = createTestRequest(amountSats: 1000)

        // When
        let result = await viewModel.evaluate(request)

        // Then
        if case .requiresApproval = result {
            // Expected
        } else {
            XCTFail("Expected requiresApproval")
        }
    }

    func testEvaluateApprovesUnderGlobalMax() async {
        // Given
        viewModel.settings = AutoPaySettings(
            globalEnabled: true,
            globalMaxAmount: 10000,
            requireConfirmationAbove: 50000
        )
        let request = createTestRequest(amountSats: 5000)

        // When
        let result = await viewModel.evaluate(request)

        // Then
        if case .approved = result {
            // Expected
        } else {
            XCTFail("Expected approved, got \(result)")
        }
    }

    func testEvaluateRequiresApprovalOverGlobalMax() async {
        // Given
        viewModel.settings = AutoPaySettings(
            globalEnabled: true,
            globalMaxAmount: 1000,
            requireConfirmationAbove: 500
        )
        let request = createTestRequest(amountSats: 5000)

        // When
        let result = await viewModel.evaluate(request)

        // Then
        if case .requiresApproval = result {
            // Expected
        } else {
            XCTFail("Expected requiresApproval")
        }
    }

    func testEvaluateMatchesAllowRule() async {
        // Given
        let rule = AutoPayRule(
            id: "rule1",
            name: "Allow trusted",
            peerPubkey: "pk:trusted",
            action: .allow,
            maxAmount: 50000
        )
        viewModel.settings = AutoPaySettings(
            globalEnabled: true,
            globalMaxAmount: 1000,
            rules: [rule]
        )
        let request = createTestRequest(amountSats: 5000, fromPubkey: "pk:trusted")

        // When
        let result = await viewModel.evaluate(request)

        // Then
        if case .approved = result {
            // Expected - rule allows higher amount
        } else {
            XCTFail("Expected approved due to rule, got \(result)")
        }
    }

    func testEvaluateMatchesDenyRule() async {
        // Given
        let rule = AutoPayRule(
            id: "rule1",
            name: "Block spammer",
            peerPubkey: "pk:spammer",
            action: .deny
        )
        viewModel.settings = AutoPaySettings(
            globalEnabled: true,
            globalMaxAmount: 100000,
            rules: [rule]
        )
        let request = createTestRequest(amountSats: 100, fromPubkey: "pk:spammer")

        // When
        let result = await viewModel.evaluate(request)

        // Then
        if case .denied = result {
            // Expected
        } else {
            XCTFail("Expected denied")
        }
    }

    // MARK: - Peer Limit Tests

    func testRecordPaymentUpdatesPeerSpending() async {
        // Given
        let peerPubkey = "pk:sender"
        let amountSats: Int64 = 1000

        // When
        await viewModel.recordPayment(peerPubkey: peerPubkey, amountSats: amountSats)

        // Then
        let spent = await viewModel.getPeerSpentToday(peerPubkey: peerPubkey)
        XCTAssertEqual(spent, 1000)
    }

    func testPeerLimitResetsDaily() async {
        // Given
        let peerPubkey = "pk:sender"

        // Set a limit that should have reset
        await viewModel.setPeerLimit(
            peerPubkey: peerPubkey,
            limit: PeerSpendingLimit(
                peerPubkey: peerPubkey,
                dailyLimit: 10000,
                spentToday: 5000,
                lastResetDate: Calendar.current.date(byAdding: .day, value: -2, to: Date())!
            )
        )

        // When
        let spent = await viewModel.getPeerSpentToday(peerPubkey: peerPubkey)

        // Then - should have reset to 0
        XCTAssertEqual(spent, 0)
    }

    // MARK: - Helper Methods

    private func createTestRequest(
        amountSats: Int64 = 1000,
        fromPubkey: String = "pk:sender"
    ) -> PaymentRequest {
        return PaymentRequest(
            id: "test-request",
            fromPubkey: fromPubkey,
            toPubkey: "pk:recipient",
            amountSats: amountSats,
            currency: "SAT",
            methodId: "lightning",
            description: "Test payment",
            direction: .incoming
        )
    }
}

