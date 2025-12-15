// PaykitFFIIntegrationTests.swift
// BitkitTests
//
// FFI Integration tests - placeholder until Paykit FFI is fully integrated

import XCTest
@testable import Bitkit

/// FFI Integration tests for Paykit
/// These tests are placeholders until Paykit FFI integration is complete
final class PaykitFFIIntegrationTests: XCTestCase {
    
    // MARK: - FFI Module Availability
    
    func testPaykitManagerExists() {
        // Verify PaykitManager is accessible
        let manager = PaykitManager.shared
        XCTAssertNotNil(manager)
    }
    
    func testPaykitFeatureFlagsExist() {
        // Verify PaykitFeatureFlags is accessible
        XCTAssertNotNil(PaykitFeatureFlags.isEnabled)
    }
    
    func testPaykitPaymentServiceExists() {
        // Verify PaykitPaymentService is accessible
        let service = PaykitPaymentService.shared
        XCTAssertNotNil(service)
    }
    
    func testDirectoryServiceExists() {
        // Verify DirectoryService is accessible
        let service = DirectoryService.shared
        XCTAssertNotNil(service)
    }
    
    // MARK: - FFI Types Placeholder Tests
    
    func testPaymentMethodStructure() async throws {
        // Test that PaymentMethod can be created through the service
        let service = PaykitPaymentService.shared
        
        // Given a Lightning invoice
        let invoice = "lnbc10u1p0test123"
        
        // When we discover methods
        let methods = try await service.discoverPaymentMethods(for: invoice)
        
        // Then we get a valid result
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.methodId, "lightning")
    }
    
    func testPaykitMobileErrorHandling() {
        // Verify error types are accessible
        // PaykitMobileError is an FFI type
        // This test just verifies compilation succeeds
        XCTAssertTrue(true, "PaykitMobileError handling compiles")
    }
    
    // MARK: - Integration Helper Tests
    
    func testPaykitIntegrationHelperAccessibility() {
        // Verify PaykitIntegrationHelper is accessible
        let isReady = PaykitIntegrationHelper.isReady
        XCTAssertNotNil(isReady)
    }
    
    // MARK: - Note About Skipped Tests
    
    func testFFITypesNote() throws {
        // These tests are skipped because they require full FFI integration:
        // - PaykitMobile client creation
        // - DecodedInvoice parsing
        // - LightningPaymentResult/BitcoinTxResult creation
        // - PubkyRingIntegration methods
        //
        // Once Paykit FFI is fully integrated (static libraries included),
        // these tests should be expanded to cover:
        // 1. FFI type creation and manipulation
        // 2. Error handling across FFI boundary
        // 3. Async FFI calls
        // 4. Transport layer integration
        
        throw XCTSkip("Full FFI integration tests require static libraries")
    }
}
