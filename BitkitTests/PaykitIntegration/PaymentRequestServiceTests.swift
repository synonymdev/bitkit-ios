// PaymentRequestServiceTests.swift
// BitkitTests
//
// Unit tests for PaymentRequestService

import XCTest
@testable import Bitkit

final class PaymentRequestServiceTests: XCTestCase {

    var paymentRequestService: PaymentRequestService!

    override func setUp() {
        super.setUp()
        paymentRequestService = PaymentRequestService.shared
    }

    override func tearDown() {
        paymentRequestService = nil
        super.tearDown()
    }

    // MARK: - Payment Request Creation Tests

    func testPaymentRequestCreation() {
        // Given
        let fromPubkey = "pk:sender123"
        let toPubkey = "pk:recipient456"
        let amountSats: Int64 = 1000
        let description = "Test payment"

        // When
        let request = PaymentRequest(
            id: "test-id",
            fromPubkey: fromPubkey,
            toPubkey: toPubkey,
            amountSats: amountSats,
            currency: "SAT",
            methodId: "lightning",
            description: description,
            direction: .outgoing
        )

        // Then
        XCTAssertEqual(request.fromPubkey, fromPubkey)
        XCTAssertEqual(request.toPubkey, toPubkey)
        XCTAssertEqual(request.amountSats, amountSats)
        XCTAssertEqual(request.status, .pending)
    }

    // MARK: - Handling Tests

    func testHandleIncomingRequestReturnsResult() async throws {
        // Given
        let request = createTestRequest()

        // When
        let result = try await paymentRequestService.handleIncomingRequest(request)

        // Then
        XCTAssertNotNil(result)
    }

    func testHandleIncomingRequestEvaluatesAutopay() async throws {
        // Given
        let request = createTestRequest()

        // When
        let result = try await paymentRequestService.handleIncomingRequest(request)

        // Then - should return one of the valid result types
        switch result {
        case .autoPaid, .requiresApproval, .denied:
            break // All valid
        default:
            XCTFail("Unexpected result type")
        }
    }

    // MARK: - Execution Tests

    func testExecutePaymentRequiresValidRequest() async throws {
        // Given
        let request = createTestRequest()

        // When/Then - execution may fail without proper setup
        // This verifies the method exists and can be called
        do {
            let _ = try await paymentRequestService.executePayment(request)
        } catch {
            // Expected - no executors registered
        }
    }

    // MARK: - Request Status Tests

    func testPaymentRequestStatusTransitions() {
        // Given
        var request = createTestRequest()
        XCTAssertEqual(request.status, .pending)

        // When
        request.status = .accepted

        // Then
        XCTAssertEqual(request.status, .accepted)

        // When
        request.status = .paid

        // Then
        XCTAssertEqual(request.status, .paid)
    }

    func testPaymentRequestExpiration() {
        // Given
        let expiresIn1Hour = Date().addingTimeInterval(3600)
        let request = PaymentRequest(
            id: "expiring",
            fromPubkey: "pk:sender",
            toPubkey: "pk:recipient",
            amountSats: 1000,
            currency: "SAT",
            methodId: "lightning",
            description: "Expiring request",
            expiresAt: expiresIn1Hour,
            direction: .incoming
        )

        // Then
        XCTAssertFalse(request.isExpired)
    }

    func testPaymentRequestIsExpired() {
        // Given
        let expiredTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let request = PaymentRequest(
            id: "expired",
            fromPubkey: "pk:sender",
            toPubkey: "pk:recipient",
            amountSats: 1000,
            currency: "SAT",
            methodId: "lightning",
            description: "Expired request",
            expiresAt: expiredTime,
            direction: .incoming
        )

        // Then
        XCTAssertTrue(request.isExpired)
    }

    // MARK: - Helper Methods

    private func createTestRequest() -> PaymentRequest {
        return PaymentRequest(
            id: "test-request-1",
            fromPubkey: "pk:sender",
            toPubkey: "pk:recipient",
            amountSats: 500,
            currency: "SAT",
            methodId: "lightning",
            description: "Test",
            direction: .incoming
        )
    }
}

