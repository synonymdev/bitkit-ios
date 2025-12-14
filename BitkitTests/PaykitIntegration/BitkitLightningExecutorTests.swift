// BitkitLightningExecutorTests.swift
// BitkitTests
//
// Unit tests for BitkitLightningExecutor

import XCTest
import CryptoKit
@testable import Bitkit

final class BitkitLightningExecutorTests: XCTestCase {

    var executor: BitkitLightningExecutor!

    override func setUp() {
        super.setUp()
        executor = BitkitLightningExecutor()
    }

    override func tearDown() {
        executor = nil
        super.tearDown()
    }

    // MARK: - decodeInvoice Tests

    func testDecodeInvoiceReturnsResult() throws {
        // Given
        let invoice = "lntb10u1p0..."

        // When
        let result = try executor.decodeInvoice(invoice: invoice)

        // Then - placeholder returns default values
        XCTAssertNotNil(result)
        XCTAssertEqual(result.expiry, 3600)
        XCTAssertFalse(result.expired)
    }

    // MARK: - estimateFee Tests

    func testEstimateFeeReturnsValue() throws {
        // Given
        let invoice = "lntb10u1p0..."

        // When
        let fee = try executor.estimateFee(invoice: invoice)

        // Then - should return default routing fee
        XCTAssertGreaterThan(fee, 0)
    }

    // MARK: - getPayment Tests

    func testGetPaymentReturnsNilForUnknown() throws {
        // Given
        let paymentHash = "unknown_payment_hash_12345"

        // When
        let result = try executor.getPayment(paymentHash: paymentHash)

        // Then
        XCTAssertNil(result)
    }

    // MARK: - verifyPreimage Tests

    func testVerifyPreimageReturnsTrueForValid() {
        // Given - SHA256 of "test" (0x74657374)
        // hash: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
        let preimage = "74657374" // "test" in hex
        let paymentHash = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

        // When
        let result = executor.verifyPreimage(preimage: preimage, paymentHash: paymentHash)

        // Then
        XCTAssertTrue(result)
    }

    func testVerifyPreimageReturnsFalseForInvalid() {
        // Given
        let preimage = "74657374" // "test" in hex
        let paymentHash = "0000000000000000000000000000000000000000000000000000000000000000"

        // When
        let result = executor.verifyPreimage(preimage: preimage, paymentHash: paymentHash)

        // Then
        XCTAssertFalse(result)
    }

    func testVerifyPreimageReturnsFalseForInvalidHex() {
        // Given
        let preimage = "not_valid_hex"
        let paymentHash = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

        // When
        let result = executor.verifyPreimage(preimage: preimage, paymentHash: paymentHash)

        // Then
        XCTAssertFalse(result)
    }

    func testVerifyPreimageIsCaseInsensitive() {
        // Given
        let preimage = "74657374"
        let paymentHashLower = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        let paymentHashUpper = "9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08"

        // When
        let resultLower = executor.verifyPreimage(preimage: preimage, paymentHash: paymentHashLower)
        let resultUpper = executor.verifyPreimage(preimage: preimage, paymentHash: paymentHashUpper)

        // Then
        XCTAssertTrue(resultLower)
        XCTAssertTrue(resultUpper)
    }

    // MARK: - SHA256 Verification Helper

    func testSHA256OfTestString() {
        // Verify our test values are correct
        let testData = Data([0x74, 0x65, 0x73, 0x74]) // "test"
        let hash = SHA256.hash(data: testData)
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(hashHex, "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
    }
}
