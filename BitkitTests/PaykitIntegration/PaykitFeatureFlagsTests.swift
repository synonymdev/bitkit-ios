// PaykitFeatureFlagsTests.swift
// BitkitTests
//
// Tests for PaykitFeatureFlags functionality.

import XCTest
@testable import Bitkit

final class PaykitFeatureFlagsTests: XCTestCase {
    
    // MARK: - Setup/Teardown
    
    override func setUp() {
        super.setUp()
        // Reset all flags to known state before each test
        resetAllFlags()
    }
    
    override func tearDown() {
        // Clean up after each test
        resetAllFlags()
        super.tearDown()
    }
    
    private func resetAllFlags() {
        UserDefaults.standard.removeObject(forKey: "paykit_enabled")
        UserDefaults.standard.removeObject(forKey: "paykit_lightning_enabled")
        UserDefaults.standard.removeObject(forKey: "paykit_onchain_enabled")
        UserDefaults.standard.removeObject(forKey: "paykit_receipt_storage_enabled")
    }
    
    // MARK: - isEnabled Tests
    
    func testIsEnabledDefaultsToFalse() {
        // Given defaults are set
        PaykitFeatureFlags.setDefaults()
        
        // Then isEnabled should be false by default
        XCTAssertFalse(PaykitFeatureFlags.isEnabled)
    }
    
    func testIsEnabledCanBeSet() {
        // When we enable Paykit
        PaykitFeatureFlags.isEnabled = true
        
        // Then it should be enabled
        XCTAssertTrue(PaykitFeatureFlags.isEnabled)
        
        // When we disable it
        PaykitFeatureFlags.isEnabled = false
        
        // Then it should be disabled
        XCTAssertFalse(PaykitFeatureFlags.isEnabled)
    }
    
    // MARK: - isLightningEnabled Tests
    
    func testIsLightningEnabledDefaultsToTrue() {
        // Given defaults are set
        PaykitFeatureFlags.setDefaults()
        
        // Then Lightning should be enabled by default
        XCTAssertTrue(PaykitFeatureFlags.isLightningEnabled)
    }
    
    func testIsLightningEnabledCanBeSet() {
        PaykitFeatureFlags.isLightningEnabled = false
        XCTAssertFalse(PaykitFeatureFlags.isLightningEnabled)
        
        PaykitFeatureFlags.isLightningEnabled = true
        XCTAssertTrue(PaykitFeatureFlags.isLightningEnabled)
    }
    
    // MARK: - isOnchainEnabled Tests
    
    func testIsOnchainEnabledDefaultsToTrue() {
        PaykitFeatureFlags.setDefaults()
        XCTAssertTrue(PaykitFeatureFlags.isOnchainEnabled)
    }
    
    func testIsOnchainEnabledCanBeSet() {
        PaykitFeatureFlags.isOnchainEnabled = false
        XCTAssertFalse(PaykitFeatureFlags.isOnchainEnabled)
        
        PaykitFeatureFlags.isOnchainEnabled = true
        XCTAssertTrue(PaykitFeatureFlags.isOnchainEnabled)
    }
    
    // MARK: - isReceiptStorageEnabled Tests
    
    func testIsReceiptStorageEnabledDefaultsToTrue() {
        PaykitFeatureFlags.setDefaults()
        XCTAssertTrue(PaykitFeatureFlags.isReceiptStorageEnabled)
    }
    
    func testIsReceiptStorageEnabledCanBeSet() {
        PaykitFeatureFlags.isReceiptStorageEnabled = false
        XCTAssertFalse(PaykitFeatureFlags.isReceiptStorageEnabled)
        
        PaykitFeatureFlags.isReceiptStorageEnabled = true
        XCTAssertTrue(PaykitFeatureFlags.isReceiptStorageEnabled)
    }
    
    // MARK: - updateFromRemoteConfig Tests
    
    func testUpdateFromRemoteConfigUpdatesAllFlags() {
        // Given all flags are disabled
        PaykitFeatureFlags.isEnabled = false
        PaykitFeatureFlags.isLightningEnabled = false
        PaykitFeatureFlags.isOnchainEnabled = false
        PaykitFeatureFlags.isReceiptStorageEnabled = false
        
        // When we update from remote config
        let config: [String: Any] = [
            "paykit_enabled": true,
            "paykit_lightning_enabled": true,
            "paykit_onchain_enabled": true,
            "paykit_receipt_storage_enabled": true
        ]
        PaykitFeatureFlags.updateFromRemoteConfig(config)
        
        // Then all flags should be updated
        XCTAssertTrue(PaykitFeatureFlags.isEnabled)
        XCTAssertTrue(PaykitFeatureFlags.isLightningEnabled)
        XCTAssertTrue(PaykitFeatureFlags.isOnchainEnabled)
        XCTAssertTrue(PaykitFeatureFlags.isReceiptStorageEnabled)
    }
    
    func testUpdateFromRemoteConfigPartialUpdate() {
        // Given initial state
        PaykitFeatureFlags.isEnabled = false
        PaykitFeatureFlags.isLightningEnabled = true
        
        // When we update only some flags
        let config: [String: Any] = [
            "paykit_enabled": true
            // Other flags not included
        ]
        PaykitFeatureFlags.updateFromRemoteConfig(config)
        
        // Then only specified flags should be updated
        XCTAssertTrue(PaykitFeatureFlags.isEnabled)
        XCTAssertTrue(PaykitFeatureFlags.isLightningEnabled) // Unchanged
    }
    
    func testUpdateFromRemoteConfigIgnoresInvalidTypes() {
        // Given
        PaykitFeatureFlags.isEnabled = false
        
        // When config has wrong types
        let config: [String: Any] = [
            "paykit_enabled": "true", // String instead of Bool
            "paykit_lightning_enabled": 1 // Int instead of Bool
        ]
        PaykitFeatureFlags.updateFromRemoteConfig(config)
        
        // Then flags should remain unchanged
        XCTAssertFalse(PaykitFeatureFlags.isEnabled)
    }
    
    // MARK: - emergencyRollback Tests
    
    func testEmergencyRollbackDisablesPaykit() {
        // Given Paykit is enabled
        PaykitFeatureFlags.isEnabled = true
        XCTAssertTrue(PaykitFeatureFlags.isEnabled)
        
        // When emergency rollback is triggered
        PaykitFeatureFlags.emergencyRollback()
        
        // Then Paykit should be disabled
        XCTAssertFalse(PaykitFeatureFlags.isEnabled)
    }
    
    // MARK: - Persistence Tests
    
    func testFlagsPersistAcrossInstances() {
        // Given we set a flag
        PaykitFeatureFlags.isEnabled = true
        
        // When we check the value (simulating app restart by reading UserDefaults directly)
        let persistedValue = UserDefaults.standard.bool(forKey: "paykit_enabled")
        
        // Then the value should be persisted
        XCTAssertTrue(persistedValue)
    }
    
    // MARK: - Concurrent Access Tests
    
    func testConcurrentFlagAccess() {
        let expectation = XCTestExpectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 100
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<100 {
            queue.async {
                // Alternate between reading and writing
                if i % 2 == 0 {
                    PaykitFeatureFlags.isEnabled = true
                } else {
                    _ = PaykitFeatureFlags.isEnabled
                }
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
}
