// AutoPayViewModelTests.swift
// BitkitTests
//
// Unit tests for AutoPayViewModel

import XCTest
@testable import Bitkit

@MainActor
final class AutoPayViewModelTests: XCTestCase {
    
    var viewModel: AutoPayViewModel!
    
    override func setUp() {
        super.setUp()
        viewModel = AutoPayViewModel(identityName: "test_\(UUID().uuidString)")
    }
    
    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }
    
    // MARK: - Load Settings Tests
    
    func testLoadSettingsLoadsFromStorage() {
        // When
        viewModel.loadSettings()
        
        // Then
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotNil(viewModel.settings)
    }
    
    func testInitialSettingsAreLoaded() {
        // Then - settings should be loaded on init
        XCTAssertNotNil(viewModel.settings)
    }
    
    // MARK: - Save Settings Tests
    
    func testSaveSettingsDoesNotThrow() throws {
        // Given
        viewModel.settings.isEnabled = true
        viewModel.settings.globalDailyLimit = 100000
        
        // When/Then - should not throw
        try viewModel.saveSettings()
    }
    
    // MARK: - Peer Limit Tests
    
    func testAddPeerLimit() throws {
        // Given
        let limit = StoredPeerLimit(
            peerPubkey: "pk:peer123",
            peerName: "Peer 123",
            limitSats: 50000,
            period: "daily"
        )
        
        // When
        try viewModel.addPeerLimit(limit)
        
        // Then
        XCTAssertGreaterThan(viewModel.peerLimits.count, 0)
    }
    
    func testDeletePeerLimit() throws {
        // Given - add a limit first
        let limit = StoredPeerLimit(
            peerPubkey: "pk:peer456",
            peerName: "Peer 456",
            limitSats: 50000,
            period: "daily"
        )
        try viewModel.addPeerLimit(limit)
        let initialCount = viewModel.peerLimits.count
        
        // When
        try viewModel.deletePeerLimit(limit)
        
        // Then
        XCTAssertLessThan(viewModel.peerLimits.count, initialCount)
    }
    
    // MARK: - Rule Tests
    
    func testAddRule() throws {
        // Given
        let rule = StoredAutoPayRule(
            name: "Test Rule",
            maxAmountSats: 10000,
            allowedMethods: ["lightning"],
            allowedPeers: []
        )
        
        // When
        try viewModel.addRule(rule)
        
        // Then
        XCTAssertGreaterThan(viewModel.rules.count, 0)
    }
    
    func testDeleteRule() throws {
        // Given - add a rule first
        let rule = StoredAutoPayRule(
            name: "Rule to Delete",
            maxAmountSats: 5000,
            allowedMethods: [],
            allowedPeers: []
        )
        try viewModel.addRule(rule)
        let initialCount = viewModel.rules.count
        
        // When
        try viewModel.deleteRule(rule)
        
        // Then
        XCTAssertLessThan(viewModel.rules.count, initialCount)
    }
    
    // MARK: - Evaluation Tests
    
    func testEvaluateWhenDisabledReturnsDenied() {
        // Given - auto-pay is disabled
        viewModel.settings.isEnabled = false
        
        // When
        let result = viewModel.evaluate(peerPubkey: "pk:test", amount: 1000, methodId: "lightning")
        
        // Then
        if case .denied(let reason) = result {
            XCTAssertTrue(reason.contains("disabled"))
        } else {
            XCTFail("Expected denied result")
        }
    }
    
    func testEvaluateExceedingDailyLimitReturnsDenied() throws {
        // Given - auto-pay is enabled with low limit
        viewModel.settings.isEnabled = true
        viewModel.settings.globalDailyLimit = 100
        try viewModel.saveSettings()
        
        // When - try to pay more than limit
        let result = viewModel.evaluate(peerPubkey: "pk:test", amount: 1000, methodId: "lightning")
        
        // Then
        if case .denied(let reason) = result {
            XCTAssertTrue(reason.contains("daily limit"))
        } else {
            XCTFail("Expected denied result")
        }
    }
    
    func testEvaluateWithMatchingRuleReturnsApproved() throws {
        // Given - auto-pay is enabled with matching rule
        viewModel.settings.isEnabled = true
        viewModel.settings.globalDailyLimit = 1000000
        try viewModel.saveSettings() // Persist settings
        viewModel.loadSettings() // Reload to ensure state is updated
        
        let rule = StoredAutoPayRule(
            name: "Allow Lightning",
            maxAmountSats: 10000,
            allowedMethods: ["lightning"],
            allowedPeers: []
        )
        try viewModel.addRule(rule)
        
        // When - payment matches rule
        let result = viewModel.evaluate(peerPubkey: "pk:test", amount: 5000, methodId: "lightning")
        
        // Then
        if case .approved = result {
            // Expected
        } else {
            XCTFail("Expected approved result, got: \(result)")
        }
    }
    
    func testEvaluateWithNoMatchingRuleReturnsNeedsApproval() throws {
        // Given - auto-pay is enabled but no matching rule
        viewModel.settings.isEnabled = true
        viewModel.settings.globalDailyLimit = 1000000
        
        // When - no rules match
        let result = viewModel.evaluate(peerPubkey: "pk:test", amount: 5000, methodId: "lightning")
        
        // Then
        if case .needsApproval = result {
            // Expected
        } else {
            XCTFail("Expected needsApproval result, got: \(result)")
        }
    }
    
    func testEvaluateExceedingPeerLimitReturnsDenied() throws {
        // Given - auto-pay is enabled with peer limit that's almost exhausted
        viewModel.settings.isEnabled = true
        viewModel.settings.globalDailyLimit = 1000000
        try viewModel.saveSettings() // Persist settings
        viewModel.loadSettings() // Reload to ensure state is updated
        
        var peerLimit = StoredPeerLimit(
            peerPubkey: "pk:limited_peer",
            peerName: "Limited Peer",
            limitSats: 1000,
            period: "daily"
        )
        // Simulate that 900 sats have already been spent
        peerLimit.spentSats = 900
        try viewModel.addPeerLimit(peerLimit)
        
        // When - try to pay more than remaining peer limit
        let result = viewModel.evaluate(peerPubkey: "pk:limited_peer", amount: 200, methodId: "lightning")
        
        // Then
        if case .denied(let reason) = result {
            XCTAssertTrue(reason.contains("peer limit"))
        } else {
            XCTFail("Expected denied result, got: \(result)")
        }
    }
}
