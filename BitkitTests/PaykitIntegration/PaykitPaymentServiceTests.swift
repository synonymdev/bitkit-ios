// PaykitPaymentServiceTests.swift
// BitkitTests
//
// Unit tests for PaykitPaymentService

import XCTest
@testable import Bitkit

final class PaykitPaymentServiceTests: XCTestCase {
    
    var paymentService: PaykitPaymentService!
    
    override func setUp() {
        super.setUp()
        paymentService = PaykitPaymentService.shared
    }
    
    override func tearDown() {
        paymentService = nil
        super.tearDown()
    }
    
    // MARK: - Payment Discovery Tests
    
    func testDiscoverLightningPaymentMethodFromInvoice() async throws {
        // Given - a Lightning invoice
        let invoice = "lnbc10u1p0testinvoice"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: invoice)
        
        // Then - should return Lightning method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "lightning")
        XCTAssertEqual(methods.first?.endpoint, invoice)
    }
    
    func testDiscoverLightningPaymentMethodFromTestnetInvoice() async throws {
        // Given - a testnet Lightning invoice
        let invoice = "lntb10u1p0testinvoice"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: invoice)
        
        // Then - should return Lightning method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "lightning")
    }
    
    func testDiscoverLightningPaymentMethodFromRegtestInvoice() async throws {
        // Given - a regtest Lightning invoice
        let invoice = "lnbcrt10u1p0testinvoice"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: invoice)
        
        // Then - should return Lightning method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "lightning")
    }
    
    func testDiscoverOnchainPaymentMethodFromBech32Address() async throws {
        // Given - a mainnet bech32 address
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then - should return onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
        XCTAssertEqual(methods.first?.endpoint, address)
    }
    
    func testDiscoverOnchainPaymentMethodFromTestnetAddress() async throws {
        // Given - a testnet bech32 address
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then - should return onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
    }
    
    func testDiscoverOnchainPaymentMethodFromRegtestAddress() async throws {
        // Given - a regtest bech32 address
        let address = "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then - should return onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
    }
    
    func testDiscoverOnchainPaymentMethodFromP2PKHAddress() async throws {
        // Given - a P2PKH address (starts with 1)
        let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then - should return onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
    }
    
    func testDiscoverOnchainPaymentMethodFromP2SHAddress() async throws {
        // Given - a P2SH address (starts with 3)
        let address = "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"
        
        // When - discovering payment methods
        let methods = try await paymentService.discoverPaymentMethods(for: address)
        
        // Then - should return onchain method
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "onchain")
    }
    
    // MARK: - Invalid Input Tests
    
    func testDiscoverPaymentMethodThrowsForInvalidInput() async throws {
        // Given - an invalid input
        let invalidInput = "invalid_payment_string"
        
        // When/Then - should throw invalidRecipient error
        do {
            _ = try await paymentService.discoverPaymentMethods(for: invalidInput)
            XCTFail("Should throw error for invalid input")
        } catch let error as PaykitPaymentError {
            if case .invalidRecipient = error {
                // Expected
            } else {
                XCTFail("Expected invalidRecipient error")
            }
        }
    }
    
    // MARK: - Payment Execution Tests (Skip without LDK)
    
    func testPayThrowsWhenNotInitialized() async throws {
        // Given - PaykitIntegrationHelper is not ready
        guard !PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit is ready - can't test notInitialized error")
        }
        
        // Given - a valid Lightning invoice
        let invoice = "lnbc10u1p0testinvoice"
        
        // When/Then - should throw notInitialized error
        do {
            _ = try await paymentService.pay(to: invoice, amountSats: nil)
            XCTFail("Should throw error when not initialized")
        } catch let error as PaykitPaymentError {
            if case .notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error")
            }
        }
    }
    
    func testPayOnchainRequiresAmount() async throws {
        // Given - PaykitIntegrationHelper is ready
        guard PaykitIntegrationHelper.isReady else {
            throw XCTSkip("Paykit not ready")
        }
        
        // Given - an onchain address without amount
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        
        // When/Then - should throw amountRequired error
        do {
            _ = try await paymentService.pay(to: address, amountSats: nil)
            XCTFail("Should throw error for missing amount")
        } catch let error as PaykitPaymentError {
            if case .amountRequired = error {
                // Expected
            } else {
                XCTFail("Expected amountRequired error")
            }
        }
    }
    
    // MARK: - Service Configuration Tests
    
    func testPaymentTimeoutIsConfigurable() {
        // Given - default timeout
        let defaultTimeout = paymentService.paymentTimeout
        
        // When - setting new timeout
        paymentService.paymentTimeout = 120.0
        
        // Then - timeout should be updated
        XCTAssertEqual(paymentService.paymentTimeout, 120.0)
        
        // Cleanup
        paymentService.paymentTimeout = defaultTimeout
    }
    
    func testAutoStoreReceiptsIsConfigurable() {
        // Given - default setting
        let defaultValue = paymentService.autoStoreReceipts
        
        // When - toggling setting
        paymentService.autoStoreReceipts = !defaultValue
        
        // Then - setting should be updated
        XCTAssertEqual(paymentService.autoStoreReceipts, !defaultValue)
        
        // Cleanup
        paymentService.autoStoreReceipts = defaultValue
    }
}
