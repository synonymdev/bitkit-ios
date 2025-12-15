// PaykitConfigManagerTests.swift
// BitkitTests
//
// Tests for PaykitConfigManager functionality.

import XCTest
@testable import Bitkit

final class PaykitConfigManagerTests: XCTestCase {
    
    var configManager: PaykitConfigManager!
    
    override func setUp() {
        super.setUp()
        configManager = PaykitConfigManager.shared
    }
    
    override func tearDown() {
        // Reset to defaults
        configManager.logLevel = .info
        configManager.defaultPaymentTimeout = 60.0
        configManager.lightningPollingInterval = 0.5
        configManager.maxRetryAttempts = 3
        configManager.retryBaseDelay = 1.0
        configManager.errorReporter = nil
        super.tearDown()
    }
    
    // MARK: - Singleton Tests
    
    func testSharedInstanceIsSingleton() {
        let instance1 = PaykitConfigManager.shared
        let instance2 = PaykitConfigManager.shared
        
        XCTAssertTrue(instance1 === instance2)
    }
    
    // MARK: - Environment Tests
    
    func testEnvironmentReturnsValidValue() {
        let environment = configManager.environment
        
        // Should be one of the valid values
        switch environment {
        case .development, .staging, .production:
            // Valid
            break
        }
        
        // In test builds, typically development
        #if DEBUG
        XCTAssertEqual(environment, .development)
        #else
        XCTAssertEqual(environment, .production)
        #endif
    }
    
    // MARK: - Log Level Tests
    
    func testLogLevelDefaultsToInfo() {
        // Reset to default
        configManager.logLevel = .info
        XCTAssertEqual(configManager.logLevel, .info)
    }
    
    func testLogLevelCanBeSet() {
        configManager.logLevel = .debug
        XCTAssertEqual(configManager.logLevel, .debug)
        
        configManager.logLevel = .error
        XCTAssertEqual(configManager.logLevel, .error)
        
        configManager.logLevel = .none
        XCTAssertEqual(configManager.logLevel, .none)
    }
    
    func testLogLevelOrdering() {
        // Verify log levels have correct ordering for filtering
        XCTAssertLessThan(PaykitLogLevel.debug.rawValue, PaykitLogLevel.info.rawValue)
        XCTAssertLessThan(PaykitLogLevel.info.rawValue, PaykitLogLevel.warning.rawValue)
        XCTAssertLessThan(PaykitLogLevel.warning.rawValue, PaykitLogLevel.error.rawValue)
        XCTAssertLessThan(PaykitLogLevel.error.rawValue, PaykitLogLevel.none.rawValue)
    }
    
    // MARK: - Timeout Configuration Tests
    
    func testDefaultPaymentTimeoutDefault() {
        XCTAssertEqual(configManager.defaultPaymentTimeout, 60.0)
    }
    
    func testDefaultPaymentTimeoutCanBeSet() {
        configManager.defaultPaymentTimeout = 120.0
        XCTAssertEqual(configManager.defaultPaymentTimeout, 120.0)
    }
    
    func testLightningPollingIntervalDefault() {
        XCTAssertEqual(configManager.lightningPollingInterval, 0.5)
    }
    
    func testLightningPollingIntervalCanBeSet() {
        configManager.lightningPollingInterval = 1.0
        XCTAssertEqual(configManager.lightningPollingInterval, 1.0)
    }
    
    // MARK: - Retry Configuration Tests
    
    func testMaxRetryAttemptsDefault() {
        XCTAssertEqual(configManager.maxRetryAttempts, 3)
    }
    
    func testMaxRetryAttemptsCanBeSet() {
        configManager.maxRetryAttempts = 5
        XCTAssertEqual(configManager.maxRetryAttempts, 5)
    }
    
    func testRetryBaseDelayDefault() {
        XCTAssertEqual(configManager.retryBaseDelay, 1.0)
    }
    
    func testRetryBaseDelayCanBeSet() {
        configManager.retryBaseDelay = 2.0
        XCTAssertEqual(configManager.retryBaseDelay, 2.0)
    }
    
    // MARK: - Error Reporting Tests
    
    func testErrorReporterDefaultsToNil() {
        configManager.errorReporter = nil
        XCTAssertNil(configManager.errorReporter)
    }
    
    func testErrorReporterCanBeSet() {
        var reportedError: Error?
        var reportedContext: [String: Any]?
        
        configManager.errorReporter = { error, context in
            reportedError = error
            reportedContext = context
        }
        
        XCTAssertNotNil(configManager.errorReporter)
    }
    
    func testReportErrorCallsErrorReporter() {
        var reportedError: Error?
        var reportedContext: [String: Any]?
        
        configManager.errorReporter = { error, context in
            reportedError = error
            reportedContext = context
        }
        
        // Create a test error
        let testError = NSError(domain: "TestDomain", code: 123)
        let testContext: [String: Any] = ["key": "value"]
        
        // Report the error
        configManager.reportError(testError, context: testContext)
        
        // Verify it was reported
        XCTAssertNotNil(reportedError)
        XCTAssertEqual((reportedError as NSError?)?.code, 123)
        XCTAssertEqual(reportedContext?["key"] as? String, "value")
    }
    
    func testReportErrorHandlesNilReporter() {
        // Given no error reporter is set
        configManager.errorReporter = nil
        
        // When we report an error
        let testError = NSError(domain: "TestDomain", code: 123)
        
        // Then it should not crash
        configManager.reportError(testError)
    }
    
    // MARK: - logPaymentDetails Tests
    
    func testLogPaymentDetailsBasedOnBuildConfig() {
        #if DEBUG
        XCTAssertTrue(configManager.logPaymentDetails)
        #else
        XCTAssertFalse(configManager.logPaymentDetails)
        #endif
    }
}
