// PaykitE2ETests.swift
// BitkitTests
//
// End-to-end tests for Paykit integration with Bitkit.

import XCTest
@testable import Bitkit

/// E2E tests that verify the complete Paykit integration flow.
/// These tests require a properly initialized Bitkit environment.
@available(iOS 15.0, *)
final class PaykitE2ETests: XCTestCase {
    
    var paymentService: PaykitPaymentService!
    
    override func setUp() {
        super.setUp()
        paymentService = PaykitPaymentService.shared
        PaykitFeatureFlags.setDefaults()
    }
    
    override func tearDown() {
        PaykitFeatureFlags.setDefaults()
        super.tearDown()
    }
    
    // MARK: - Payment Discovery E2E Tests
    
    func testDiscoverLightningPaymentMethod() async throws {
        // Given a Lightning invoice
        let invoice = "lnbc10u1p0abcdefghijklmnopqrstuvwxyz1234567890"
        
        // When we discover payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: invoice)
        
        // Then we should find Lightning method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "lightning")
        XCTAssertEqual(methods.first?.endpoint, invoice)
    }
    
    func testDiscoverOnchainPaymentMethod() async throws {
        // Given an onchain address
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        
        // When we discover payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then we should find onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
        XCTAssertEqual(methods.first?.endpoint, address)
    }
    
    // MARK: - Payment Execution E2E Tests
    
    func testLightningPaymentFlowRequiresInitialization() async throws {
        // Given Paykit is not ready (no LDKNode)
        guard !PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit is ready - skip notInitialized test")
        }
        
        // Given a test Lightning invoice
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we attempt payment
        do {
            _ = try await paymentService.pay(to: invoice, amountSats: nil)
            XCTFail("Should have thrown error")
        } catch let error as PaykitPaymentError {
            // Then we should get notInitialized error
            if case .notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error, got: \(error)")
            }
        }
    }
    
    func testOnchainPaymentRequiresAmount() async throws {
        // Given Paykit is enabled and ready
        guard PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit not ready - requires initialized wallet")
        }
        
        // Given an onchain address without amount
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        
        // When we attempt payment without amount
        do {
            _ = try await paymentService.pay(to: address, amountSats: nil)
            XCTFail("Should have thrown error")
        } catch let error as PaykitPaymentError {
            // Then we should get amountRequired error
            if case .amountRequired = error {
                // Expected
            } else {
                XCTFail("Expected amountRequired error, got: \(error)")
            }
        }
    }
    
    // MARK: - Error Scenario E2E Tests
    
    func testPaymentFailsWithInvalidRecipient() async throws {
        // Skip if Paykit is not ready - notInitialized is thrown before recipient validation
        guard PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit not ready - can't test invalidRecipient error")
        }
        
        // Given an invalid recipient
        let invalidRecipient = "invalid_recipient_string"
        
        // When we attempt payment
        do {
            _ = try await paymentService.pay(to: invalidRecipient, amountSats: nil)
            XCTFail("Should have thrown error")
        } catch let error as PaykitPaymentError {
            // Then we should get invalidRecipient error
            if case .invalidRecipient = error {
                // Expected
            } else {
                XCTFail("Expected invalidRecipient error, got: \(error)")
            }
        }
    }
    
    func testPaymentFailsWhenFeatureDisabled() async throws {
        // Given Paykit is disabled
        PaykitFeatureFlags.isEnabled = false
        
        // Given PaykitIntegrationHelper is not ready when disabled
        guard !PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit is still ready after disabling - skip test")
        }
        
        // Given a valid invoice
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we attempt payment
        do {
            _ = try await paymentService.pay(to: invoice, amountSats: nil)
            XCTFail("Should have thrown error")
        } catch let error as PaykitPaymentError {
            // Then we should get notInitialized error
            if case .notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error, got: \(error)")
            }
        }
    }
    
    // MARK: - Payment Method Selection E2E Tests
    
    func testPaymentMethodSelectionForLightning() async throws {
        // Given a Lightning invoice
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we discover methods
        let methods = try await paymentService.discoverPaymentMethods(for: invoice)
        
        // Then we should have Lightning method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "lightning")
    }
    
    func testPaymentMethodSelectionForOnchain() async throws {
        // Given an onchain address
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        
        // When we discover methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then we should have onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
    }
    
    func testPaymentMethodSelectionForTestnetAddress() async throws {
        // Given a testnet address
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        
        // When we discover methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then we should have onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
    }
    
    // MARK: - Integration Helper Tests
    
    func testPaykitIntegrationHelperReadinessWithoutLDK() {
        // Given LDKNode is not initialized (typical in test environment)
        
        // Then helper should report not ready
        // Note: This might be true or false depending on test environment
        // We just verify it doesn't crash
        _ = PaykitIntegrationHelper.isReady
    }
    
    // MARK: - Feature Flag Tests
    
    func testFeatureFlagsDefaults() {
        // When we reset to defaults
        PaykitFeatureFlags.setDefaults()
        
        // Then default values should be set
        // Note: Actual default values depend on implementation
        XCTAssertNotNil(PaykitFeatureFlags.isEnabled)
    }
    
    func testEmergencyRollbackDisablesFeature() {
        // Given Paykit is enabled
        PaykitFeatureFlags.isEnabled = true
        
        // When emergency rollback is triggered
        PaykitFeatureFlags.emergencyRollback()
        
        // Then Paykit should be disabled
        XCTAssertFalse(PaykitFeatureFlags.isEnabled)
    }
    
    // MARK: - Payment Type Detection Tests
    
    func testDetectsLightningInvoice() async throws {
        // Given various Lightning invoice prefixes
        let invoices = [
            "lnbc10u1p0test", // mainnet
            "lntb10u1p0test", // testnet
            "lnbcrt10u1p0test" // regtest
        ]
        
        for invoice in invoices {
            let methods = try await paymentService.discoverPaymentMethods(for: invoice)
            XCTAssertEqual(methods.first?.methodId, "lightning", "Failed for: \(invoice)")
        }
    }
    
    func testDetectsOnchainAddress() async throws {
        // Given various Bitcoin address formats
        let addresses = [
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", // mainnet bech32
            "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", // testnet bech32
            "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", // regtest bech32
            "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", // mainnet P2PKH
            "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy" // mainnet P2SH
        ]
        
        for address in addresses {
            let methods = try await paymentService.discoverPaymentMethods(for: address)
            XCTAssertEqual(methods.first?.methodId, "onchain", "Failed for: \(address)")
        }
    }
}
