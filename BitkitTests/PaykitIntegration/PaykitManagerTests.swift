// PaykitManagerTests.swift
// BitkitTests
//
// Unit tests for PaykitManager

import XCTest
@testable import Bitkit

final class PaykitManagerTests: XCTestCase {

    var manager: PaykitManager!

    override func setUp() {
        super.setUp()
        // Reset singleton state for testing
        PaykitManager.shared.reset()
        manager = PaykitManager.shared
    }

    override func tearDown() {
        manager.reset()
        manager = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testManagerIsNotInitializedByDefault() {
        XCTAssertFalse(manager.isInitialized)
    }

    func testManagerHasNoExecutorsByDefault() {
        XCTAssertFalse(manager.hasExecutors)
    }

    func testInitializeSetsIsInitializedToTrue() throws {
        // When
        try manager.initialize()

        // Then
        XCTAssertTrue(manager.isInitialized)
    }

    func testInitializeIsIdempotent() throws {
        // When
        try manager.initialize()
        try manager.initialize() // Should not throw

        // Then
        XCTAssertTrue(manager.isInitialized)
    }

    // MARK: - Executor Registration Tests

    func testRegisterExecutorsThrowsIfNotInitialized() {
        // When/Then
        XCTAssertThrowsError(try manager.registerExecutors()) { error in
            XCTAssertTrue(error is PaykitError)
            if case PaykitError.notInitialized = error {
                // Expected
            } else {
                XCTFail("Expected notInitialized error")
            }
        }
    }

    func testRegisterExecutorsSucceedsAfterInitialization() throws {
        // Given
        try manager.initialize()

        // When
        try manager.registerExecutors()

        // Then
        XCTAssertTrue(manager.hasExecutors)
    }

    func testRegisterExecutorsIsIdempotent() throws {
        // Given
        try manager.initialize()

        // When
        try manager.registerExecutors()
        try manager.registerExecutors() // Should not throw

        // Then
        XCTAssertTrue(manager.hasExecutors)
    }

    // MARK: - Network Configuration Tests

    func testNetworkConfigurationIsSet() {
        // Then - verify network configs are set
        let validBitcoinNetworks: [BitcoinNetworkConfig] = [.mainnet, .testnet, .regtest]
        let validLightningNetworks: [LightningNetworkConfig] = [.mainnet, .testnet, .regtest]

        XCTAssertTrue(validBitcoinNetworks.contains(manager.bitcoinNetwork))
        XCTAssertTrue(validLightningNetworks.contains(manager.lightningNetwork))
    }

    // MARK: - Reset Tests

    func testResetClearsInitializationState() throws {
        // Given
        try manager.initialize()
        try manager.registerExecutors()
        XCTAssertTrue(manager.isInitialized)
        XCTAssertTrue(manager.hasExecutors)

        // When
        manager.reset()

        // Then
        XCTAssertFalse(manager.isInitialized)
        XCTAssertFalse(manager.hasExecutors)
    }

    func testCanReinitializeAfterReset() throws {
        // Given
        try manager.initialize()
        manager.reset()

        // When
        try manager.initialize()

        // Then
        XCTAssertTrue(manager.isInitialized)
    }

    // MARK: - Singleton Tests

    func testSharedReturnsSameInstance() {
        // When
        let instance1 = PaykitManager.shared
        let instance2 = PaykitManager.shared

        // Then
        XCTAssertTrue(instance1 === instance2)
    }
}
