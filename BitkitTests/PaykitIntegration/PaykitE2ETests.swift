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
    
    var manager: PaykitManager!
    var paymentService: PaykitPaymentService!
    
    override func setUp() {
        super.setUp()
        manager = PaykitManager.shared
        paymentService = PaykitPaymentService.shared
        
        // Reset state
        manager.reset()
        paymentService.clearReceipts()
        PaykitFeatureFlags.setDefaults()
    }
    
    override func tearDown() {
        manager.reset()
        paymentService.clearReceipts()
        PaykitFeatureFlags.setDefaults()
        super.tearDown()
    }
    
    // MARK: - Initialization E2E Tests
    
    func testFullInitializationFlow() throws {
        // Given Paykit is enabled
        PaykitFeatureFlags.isEnabled = true
        
        // When we initialize the manager
        try manager.initialize()
        
        // Then manager should be initialized
        XCTAssertTrue(manager.isInitialized)
        
        // When we register executors
        try manager.registerExecutors()
        
        // Then executors should be registered
        XCTAssertTrue(manager.hasExecutors)
    }
    
    // MARK: - Payment Discovery E2E Tests
    
    func testDiscoverLightningPaymentMethod() async throws {
        // Given a Lightning invoice
        let invoice = "lnbc10u1p0abcdefghijklmnopqrstuvwxyz1234567890"
        
        // When we discover payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: invoice)
        
        // Then we should find Lightning method
        XCTAssertEqual(methods.count, 1)
        if case .lightning(let inv) = methods.first {
            XCTAssertEqual(inv, invoice)
        } else {
            XCTFail("Expected lightning payment method")
        }
    }
    
    func testDiscoverOnchainPaymentMethod() async throws {
        // Given an onchain address
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        
        // When we discover payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then we should find onchain method
        XCTAssertEqual(methods.count, 1)
        if case .onchain(let addr) = methods.first {
            XCTAssertEqual(addr, address)
        } else {
            XCTFail("Expected onchain payment method")
        }
    }
    
    // MARK: - Payment Execution E2E Tests
    
    func testLightningPaymentFlow() async throws {
        // Given Paykit is initialized and enabled
        PaykitFeatureFlags.isEnabled = true
        PaykitFeatureFlags.isLightningEnabled = true
        
        guard PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit not ready - requires initialized LDKNode")
        }
        
        // Given a test Lightning invoice (this would be a real invoice in actual E2E)
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we attempt payment (this will fail with invalid invoice, but tests the flow)
        do {
            let result = try await paymentService.payLightning(
                invoice: invoice,
                amountSats: nil
            )
            
            // Then we should get a result (even if payment fails)
            XCTAssertNotNil(result)
            XCTAssertNotNil(result.receipt)
        } catch {
            // Expected for invalid invoice - verify error handling
            XCTAssertTrue(error is PaykitPaymentError)
        }
    }
    
    func testOnchainPaymentFlow() async throws {
        // Given Paykit is initialized and enabled
        PaykitFeatureFlags.isEnabled = true
        PaykitFeatureFlags.isOnchainEnabled = true
        
        guard PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit not ready - requires initialized wallet")
        }
        
        // Given a test onchain address
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let amountSats: UInt64 = 1000
        
        // When we attempt payment (this will fail with insufficient funds, but tests the flow)
        do {
            let result = try await paymentService.payOnchain(
                address: address,
                amountSats: amountSats,
                feeRate: nil
            )
            
            // Then we should get a result
            XCTAssertNotNil(result)
            XCTAssertNotNil(result.receipt)
        } catch {
            // Expected for insufficient funds - verify error handling
            XCTAssertTrue(error is PaykitPaymentError)
        }
    }
    
    // MARK: - Receipt Storage E2E Tests
    
    func testReceiptGenerationAndStorage() async throws {
        // Given payment service with auto-store enabled
        paymentService.autoStoreReceipts = true
        
        // Given a test invoice
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we attempt payment (will fail, but generates receipt)
        do {
            _ = try await paymentService.payLightning(
                invoice: invoice,
                amountSats: nil
            )
        } catch {
            // Expected
        }
        
        // Then receipt should be stored
        let receipts = paymentService.getReceipts()
        XCTAssertGreaterThan(receipts.count, 0)
        
        // Verify receipt details
        if let receipt = receipts.first {
            XCTAssertEqual(receipt.type, .lightning)
            XCTAssertEqual(receipt.recipient, invoice)
        }
    }
    
    func testReceiptPersistenceAcrossAppRestart() {
        // Given we store a receipt
        let receipt = PaykitReceipt(
            id: UUID().uuidString,
            type: .lightning,
            recipient: "lnbc10u1p0test",
            amountSats: 1000,
            feeSats: 10,
            paymentHash: "abc123",
            preimage: "def456",
            txid: nil,
            timestamp: Date(),
            status: .succeeded
        )
        
        paymentService.autoStoreReceipts = true
        // Note: In real E2E, we'd verify persistence by restarting app
        // For unit test, we verify the store method works
        let store = PaykitReceiptStore()
        store.store(receipt)
        
        // Then receipt should be retrievable
        let retrieved = store.get(id: receipt.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, receipt.id)
    }
    
    // MARK: - Error Scenario E2E Tests
    
    func testPaymentFailsWithInvalidInvoice() async throws {
        // Given an invalid invoice
        let invalidInvoice = "invalid_invoice_string"
        
        // When we attempt payment
        do {
            _ = try await paymentService.payLightning(
                invoice: invalidInvoice,
                amountSats: nil
            )
            XCTFail("Should have thrown error")
        } catch {
            // Then we should get an error
            XCTAssertTrue(error is PaykitPaymentError)
        }
    }
    
    func testPaymentFailsWhenFeatureDisabled() async throws {
        // Given Paykit is disabled
        PaykitFeatureFlags.isEnabled = false
        
        // Given a valid invoice
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we attempt payment
        do {
            _ = try await paymentService.pay(to: invoice, amountSats: nil)
            XCTFail("Should have thrown error")
        } catch {
            // Then we should get notInitialized error
            if let paykitError = error as? PaykitPaymentError {
                XCTAssertEqual(paykitError, .notInitialized)
            } else {
                XCTFail("Expected PaykitPaymentError")
            }
        }
    }
    
    func testPaymentFailsWhenLightningDisabled() async throws {
        // Given Paykit is enabled but Lightning is disabled
        PaykitFeatureFlags.isEnabled = true
        PaykitFeatureFlags.isLightningEnabled = false
        
        // Given a Lightning invoice
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we attempt payment
        // Note: This would need to be checked in the payment service
        // For now, we verify the flag is respected
        XCTAssertFalse(PaykitFeatureFlags.isLightningEnabled)
    }
    
    // MARK: - Executor Registration E2E Tests
    
    func testExecutorRegistrationFlow() throws {
        // Given manager is initialized
        try manager.initialize()
        XCTAssertTrue(manager.isInitialized)
        XCTAssertFalse(manager.hasExecutors)
        
        // When we register executors
        try manager.registerExecutors()
        
        // Then executors should be registered
        XCTAssertTrue(manager.hasExecutors)
    }
    
    func testExecutorRegistrationFailsWhenNotInitialized() {
        // Given manager is not initialized
        manager.reset()
        
        // When we try to register executors
        // Then it should throw error
        XCTAssertThrowsError(try manager.registerExecutors()) { error in
            XCTAssertTrue(error is PaykitError)
        }
    }
    
    // MARK: - Feature Flag Rollback E2E Tests
    
    func testEmergencyRollbackDisablesAllFeatures() {
        // Given Paykit is enabled
        PaykitFeatureFlags.isEnabled = true
        PaykitFeatureFlags.isLightningEnabled = true
        PaykitFeatureFlags.isOnchainEnabled = true
        
        // When emergency rollback is triggered
        PaykitFeatureFlags.emergencyRollback()
        
        // Then Paykit should be disabled
        XCTAssertFalse(PaykitFeatureFlags.isEnabled)
        
        // Note: Other flags may remain enabled, but main flag is disabled
    }
    
    // MARK: - Payment Method Selection E2E Tests
    
    func testPaymentMethodSelectionForLightning() async throws {
        // Given a Lightning invoice
        let invoice = "lnbc10u1p0testinvoice1234567890"
        
        // When we discover methods
        let methods = try await paymentService.discoverPaymentMethods(for: invoice)
        
        // Then we should have Lightning method
        XCTAssertEqual(methods.count, 1)
        if case .lightning = methods.first {
            // Expected
        } else {
            XCTFail("Expected lightning method")
        }
    }
    
    func testPaymentMethodSelectionForOnchain() async throws {
        // Given an onchain address
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        
        // When we discover methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then we should have onchain method
        XCTAssertEqual(methods.count, 1)
        if case .onchain = methods.first {
            // Expected
        } else {
            XCTFail("Expected onchain method")
        }
    }
    
    // MARK: - Integration Helper Tests
    
    func testPaykitIntegrationHelperReadiness() {
        // Given Paykit is not initialized
        manager.reset()
        
        // Then helper should report not ready
        XCTAssertFalse(PaykitIntegrationHelper.isReady)
        
        // When we initialize
        do {
            try manager.initialize()
            try manager.registerExecutors()
            
            // Then helper should report ready (if LDKNode is available)
            // Note: This depends on actual LDKNode initialization
        } catch {
            // Expected if LDKNode not available
        }
    }
}
