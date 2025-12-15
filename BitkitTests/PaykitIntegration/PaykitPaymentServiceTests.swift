// PaykitPaymentServiceTests.swift
// BitkitTests
//
// Unit tests for PaykitPaymentService

import XCTest
@testable import Bitkit

final class PaykitPaymentServiceTests: XCTestCase {

    var service: PaykitPaymentService!

    override func setUp() {
        super.setUp()
        service = PaykitPaymentService.shared
        service.clearReceipts()
    }

    override func tearDown() {
        service.clearReceipts()
        service = nil
        super.tearDown()
    }

    // MARK: - Payment Type Detection Tests

    func testDetectsLightningInvoiceMainnet() async throws {
        // Given
        let invoice = "lnbc10u1p0abcdef..."

        // When
        let methods = try await service.discoverPaymentMethods(for: invoice)

        // Then
        XCTAssertEqual(methods.count, 1)
        if case .lightning(let inv) = methods.first {
            XCTAssertEqual(inv, invoice)
        } else {
            XCTFail("Expected lightning payment method")
        }
    }

    func testDetectsLightningInvoiceTestnet() async throws {
        // Given
        let invoice = "lntb10u1p0abcdef..."

        // When
        let methods = try await service.discoverPaymentMethods(for: invoice)

        // Then
        XCTAssertEqual(methods.count, 1)
        if case .lightning = methods.first {
            // Expected
        } else {
            XCTFail("Expected lightning payment method")
        }
    }

    func testDetectsLightningInvoiceRegtest() async throws {
        // Given
        let invoice = "lnbcrt10u1p0abcdef..."

        // When
        let methods = try await service.discoverPaymentMethods(for: invoice)

        // Then
        XCTAssertEqual(methods.count, 1)
        if case .lightning = methods.first {
            // Expected
        } else {
            XCTFail("Expected lightning payment method")
        }
    }

    func testDetectsOnchainAddressBech32Mainnet() async throws {
        // Given
        let address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

        // When
        let methods = try await service.discoverPaymentMethods(for: address)

        // Then
        XCTAssertEqual(methods.count, 1)
        if case .onchain(let addr) = methods.first {
            XCTAssertEqual(addr, address)
        } else {
            XCTFail("Expected onchain payment method")
        }
    }

    func testDetectsOnchainAddressBech32Testnet() async throws {
        // Given
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"

        // When
        let methods = try await service.discoverPaymentMethods(for: address)

        // Then
        XCTAssertEqual(methods.count, 1)
        if case .onchain = methods.first {
            // Expected
        } else {
            XCTFail("Expected onchain payment method")
        }
    }

    func testDetectsOnchainAddressLegacy() async throws {
        // Given - Legacy P2PKH address
        let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

        // When
        let methods = try await service.discoverPaymentMethods(for: address)

        // Then
        XCTAssertEqual(methods.count, 1)
        if case .onchain = methods.first {
            // Expected
        } else {
            XCTFail("Expected onchain payment method")
        }
    }

    func testDetectsOnchainAddressP2SH() async throws {
        // Given - P2SH address
        let address = "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"

        // When
        let methods = try await service.discoverPaymentMethods(for: address)

        // Then
        XCTAssertEqual(methods.count, 1)
        if case .onchain = methods.first {
            // Expected
        } else {
            XCTFail("Expected onchain payment method")
        }
    }

    func testThrowsForInvalidRecipient() async {
        // Given
        let invalid = "not_a_valid_address_or_invoice"

        // When/Then
        do {
            _ = try await service.discoverPaymentMethods(for: invalid)
            XCTFail("Expected to throw")
        } catch let error as PaykitPaymentError {
            if case .invalidRecipient = error {
                // Expected
            } else {
                XCTFail("Expected invalidRecipient error")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Receipt Store Tests

    func testReceiptStoreIsEmptyInitially() {
        // When
        let receipts = service.getReceipts()

        // Then
        XCTAssertTrue(receipts.isEmpty)
    }

    func testGetReceiptByIdReturnsNilForUnknown() {
        // When
        let receipt = service.getReceipt(id: "unknown_id")

        // Then
        XCTAssertNil(receipt)
    }

    func testClearReceiptsRemovesAll() {
        // This is implicitly tested by setUp/tearDown
        let receipts = service.getReceipts()
        XCTAssertTrue(receipts.isEmpty)
    }

    // MARK: - Error Message Tests

    func testNotInitializedErrorMessage() {
        let error = PaykitPaymentError.notInitialized
        XCTAssertEqual(error.userMessage, "Please wait for the app to initialize")
    }

    func testInvalidRecipientErrorMessage() {
        let error = PaykitPaymentError.invalidRecipient("bad_address")
        XCTAssertEqual(error.userMessage, "Please check the payment address or invoice")
    }

    func testAmountRequiredErrorMessage() {
        let error = PaykitPaymentError.amountRequired
        XCTAssertEqual(error.userMessage, "Please enter an amount")
    }

    func testInsufficientFundsErrorMessage() {
        let error = PaykitPaymentError.insufficientFunds
        XCTAssertEqual(error.userMessage, "You don't have enough funds for this payment")
    }

    func testPaymentFailedErrorMessage() {
        let error = PaykitPaymentError.paymentFailed("Route not found")
        XCTAssertEqual(error.userMessage, "Payment could not be completed. Please try again.")
    }

    func testTimeoutErrorMessage() {
        let error = PaykitPaymentError.timeout
        XCTAssertEqual(error.userMessage, "Payment is taking longer than expected")
    }

    func testUnsupportedPaymentTypeErrorMessage() {
        let error = PaykitPaymentError.unsupportedPaymentType
        XCTAssertEqual(error.userMessage, "This payment type is not supported yet")
    }

    func testUnknownErrorMessage() {
        let error = PaykitPaymentError.unknown("Something went wrong")
        XCTAssertEqual(error.userMessage, "An unexpected error occurred")
    }

    // MARK: - Receipt Type Tests

    func testReceiptTypeEnumValues() {
        XCTAssertEqual(PaykitReceiptType.lightning.rawValue, "lightning")
        XCTAssertEqual(PaykitReceiptType.onchain.rawValue, "onchain")
    }

    func testReceiptStatusEnumValues() {
        XCTAssertEqual(PaykitReceiptStatus.pending.rawValue, "pending")
        XCTAssertEqual(PaykitReceiptStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(PaykitReceiptStatus.failed.rawValue, "failed")
    }

    // MARK: - Configuration Tests

    func testDefaultPaymentTimeout() {
        XCTAssertEqual(service.paymentTimeout, 60.0)
    }

    func testDefaultAutoStoreReceipts() {
        XCTAssertTrue(service.autoStoreReceipts)
    }

    func testPaymentTimeoutCanBeChanged() {
        // When
        service.paymentTimeout = 120.0

        // Then
        XCTAssertEqual(service.paymentTimeout, 120.0)

        // Cleanup
        service.paymentTimeout = 60.0
    }

    func testAutoStoreReceiptsCanBeDisabled() {
        // When
        service.autoStoreReceipts = false

        // Then
        XCTAssertFalse(service.autoStoreReceipts)

        // Cleanup
        service.autoStoreReceipts = true
    }
}

// MARK: - PaykitReceiptStore Tests

final class PaykitReceiptStoreTests: XCTestCase {

    var store: PaykitReceiptStore!

    override func setUp() {
        super.setUp()
        store = PaykitReceiptStore()
    }

    override func tearDown() {
        store.clear()
        store = nil
        super.tearDown()
    }

    func testStoreAndRetrieveReceipt() {
        // Given
        let receipt = PaykitReceipt(
            id: "test_id",
            type: .lightning,
            recipient: "lnbc...",
            amountSats: 10000,
            feeSats: 100,
            paymentHash: "abc123",
            preimage: "def456",
            txid: nil,
            timestamp: Date(),
            status: .succeeded
        )

        // When
        store.store(receipt)
        let retrieved = store.get(id: "test_id")

        // Then
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "test_id")
        XCTAssertEqual(retrieved?.amountSats, 10000)
    }

    func testGetAllReturnsReceiptsSortedByTimestamp() {
        // Given
        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        let oldReceipt = PaykitReceipt(
            id: "old",
            type: .lightning,
            recipient: "lnbc...",
            amountSats: 1000,
            feeSats: 10,
            paymentHash: nil,
            preimage: nil,
            txid: nil,
            timestamp: oldDate,
            status: .succeeded
        )

        let newReceipt = PaykitReceipt(
            id: "new",
            type: .onchain,
            recipient: "bc1...",
            amountSats: 2000,
            feeSats: 20,
            paymentHash: nil,
            preimage: nil,
            txid: "txid123",
            timestamp: newDate,
            status: .pending
        )

        // When
        store.store(oldReceipt)
        store.store(newReceipt)
        let all = store.getAll()

        // Then
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.id, "new") // Newer first
        XCTAssertEqual(all.last?.id, "old")
    }

    func testClearRemovesAllReceipts() {
        // Given
        let receipt = PaykitReceipt(
            id: "test",
            type: .lightning,
            recipient: "lnbc...",
            amountSats: 1000,
            feeSats: 10,
            paymentHash: nil,
            preimage: nil,
            txid: nil,
            timestamp: Date(),
            status: .succeeded
        )
        store.store(receipt)
        XCTAssertEqual(store.getAll().count, 1)

        // When
        store.clear()

        // Then
        XCTAssertEqual(store.getAll().count, 0)
    }

    func testGetReturnsNilForUnknownId() {
        // When
        let result = store.get(id: "nonexistent")

        // Then
        XCTAssertNil(result)
    }
}
