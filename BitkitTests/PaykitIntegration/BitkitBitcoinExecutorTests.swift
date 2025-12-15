// BitkitBitcoinExecutorTests.swift
// BitkitTests
//
// Unit tests for BitkitBitcoinExecutor

import XCTest
@testable import Bitkit

final class BitkitBitcoinExecutorTests: XCTestCase {

    var executor: BitkitBitcoinExecutor!

    override func setUp() {
        super.setUp()
        executor = BitkitBitcoinExecutor()
    }

    override func tearDown() {
        executor = nil
        super.tearDown()
    }

    // MARK: - sendToAddress Tests

    func testSendToAddressReturnsResult() {
        // Note: Full testing requires mocking LightningService
        // This test verifies the executor can be instantiated
        XCTAssertNotNil(executor)
    }

    // MARK: - estimateFee Tests

    func testEstimateFeeReturnsValue() throws {
        // Given
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let amountSats: UInt64 = 10000

        // When
        let fee = try executor.estimateFee(address: address, amountSats: amountSats, targetBlocks: 6)

        // Then - should return a fallback fee
        XCTAssertGreaterThan(fee, 0)
    }

    func testEstimateFeeScalesWithPriority() throws {
        // Given
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let amountSats: UInt64 = 10000

        // When
        let highPriorityFee = try executor.estimateFee(address: address, amountSats: amountSats, targetBlocks: 1)
        let normalFee = try executor.estimateFee(address: address, amountSats: amountSats, targetBlocks: 3)
        let lowFee = try executor.estimateFee(address: address, amountSats: amountSats, targetBlocks: 10)

        // Then - high priority should have higher fee
        XCTAssertGreaterThanOrEqual(highPriorityFee, normalFee)
        XCTAssertGreaterThanOrEqual(normalFee, lowFee)
    }

    // MARK: - getTransaction Tests

    func testGetTransactionReturnsNilForUnknown() throws {
        // Given
        let txid = "unknown_txid_12345"

        // When
        let result = try executor.getTransaction(txid: txid)

        // Then
        XCTAssertNil(result)
    }

    // MARK: - verifyTransaction Tests

    func testVerifyTransactionReturnsFalseForUnknown() throws {
        // Given
        let txid = "unknown_txid_12345"
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let amountSats: UInt64 = 10000

        // When
        let result = try executor.verifyTransaction(txid: txid, address: address, amountSats: amountSats)

        // Then
        XCTAssertFalse(result)
    }
}
