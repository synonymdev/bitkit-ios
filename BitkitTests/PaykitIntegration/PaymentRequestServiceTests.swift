// PaymentRequestServiceTests.swift
// BitkitTests
//
// Unit tests for PaymentRequestService and related types

import XCTest
@testable import Bitkit

final class PaymentRequestServiceTests: XCTestCase {
    
    // MARK: - BitkitPaymentRequest Model Tests
    
    func testBitkitPaymentRequestInitialization() {
        // Given - request parameters
        let id = UUID().uuidString
        let fromPubkey = "pk:sender123"
        let toPubkey = "pk:receiver456"
        let amountSats: Int64 = 10000
        let currency = "sats"
        let methodId = "lightning"
        let description = "Test payment"
        let now = Date()
        let expiry = now.addingTimeInterval(3600) // 1 hour
        
        // When - creating a request
        let request = BitkitPaymentRequest(
            id: id,
            fromPubkey: fromPubkey,
            toPubkey: toPubkey,
            amountSats: amountSats,
            currency: currency,
            methodId: methodId,
            description: description,
            createdAt: now,
            expiresAt: expiry,
            status: .pending,
            direction: .incoming
        )
        
        // Then - properties should be set correctly
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.fromPubkey, fromPubkey)
        XCTAssertEqual(request.toPubkey, toPubkey)
        XCTAssertEqual(request.amountSats, amountSats)
        XCTAssertEqual(request.methodId, methodId)
        XCTAssertEqual(request.description, description)
        XCTAssertEqual(request.status, .pending)
        XCTAssertEqual(request.direction, .incoming)
    }
    
    func testPaymentRequestStatusValues() {
        // Verify all status values exist
        XCTAssertNotNil(PaymentRequestStatus.pending)
        XCTAssertNotNil(PaymentRequestStatus.accepted)
        XCTAssertNotNil(PaymentRequestStatus.declined)
        XCTAssertNotNil(PaymentRequestStatus.expired)
        XCTAssertNotNil(PaymentRequestStatus.paid)
    }
    
    func testRequestDirectionValues() {
        // Verify direction values exist
        XCTAssertNotNil(RequestDirection.incoming)
        XCTAssertNotNil(RequestDirection.outgoing)
    }
    
    func testBitkitPaymentRequestCounterpartyName() {
        // Given - incoming request (from = counterparty)
        let incomingRequest = BitkitPaymentRequest(
            id: "test-1",
            fromPubkey: "pk:longpubkey12345678901234567890",
            toPubkey: "pk:me",
            amountSats: 1000,
            currency: "sats",
            methodId: "lightning",
            description: "Test",
            createdAt: Date(),
            expiresAt: nil,
            status: .pending,
            direction: .incoming
        )
        
        // Then - counterpartyName should be truncated fromPubkey
        XCTAssertTrue(incomingRequest.counterpartyName.contains("..."))
        
        // Given - outgoing request (to = counterparty)
        let outgoingRequest = BitkitPaymentRequest(
            id: "test-2",
            fromPubkey: "pk:me",
            toPubkey: "pk:longpubkey12345678901234567890",
            amountSats: 1000,
            currency: "sats",
            methodId: "lightning",
            description: "Test",
            createdAt: Date(),
            expiresAt: nil,
            status: .pending,
            direction: .outgoing
        )
        
        // Then - counterpartyName should be truncated toPubkey
        XCTAssertTrue(outgoingRequest.counterpartyName.contains("..."))
    }
    
    func testBitkitPaymentRequestCodable() throws {
        // Given - a request
        let original = BitkitPaymentRequest(
            id: "test-codable",
            fromPubkey: "pk:from",
            toPubkey: "pk:to",
            amountSats: 5000,
            currency: "sats",
            methodId: "onchain",
            description: "Codable test",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(7200),
            status: .accepted,
            direction: .outgoing
        )
        
        // When - encoding and decoding
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BitkitPaymentRequest.self, from: data)
        
        // Then - decoded should match original
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.fromPubkey, original.fromPubkey)
        XCTAssertEqual(decoded.toPubkey, original.toPubkey)
        XCTAssertEqual(decoded.amountSats, original.amountSats)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.direction, original.direction)
    }
    
    // MARK: - PaymentRequestStorage Tests
    
    func testPaymentRequestStorageAddAndRetrieve() throws {
        // Given - a storage instance and a request
        let storage = PaymentRequestStorage(identityName: "test_\(UUID().uuidString)")
        let request = BitkitPaymentRequest(
            id: "storage-test-\(UUID().uuidString)",
            fromPubkey: "pk:from",
            toPubkey: "pk:to",
            amountSats: 2000,
            currency: "sats",
            methodId: "lightning",
            description: "Storage test",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .pending,
            direction: .incoming
        )
        
        // When - adding
        try storage.addRequest(request)
        
        // Then - should be retrievable
        let retrieved = storage.getRequest(id: request.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, request.id)
    }
    
    func testPaymentRequestStorageDelete() throws {
        // Given - a stored request
        let storage = PaymentRequestStorage(identityName: "test_\(UUID().uuidString)")
        let request = BitkitPaymentRequest(
            id: "delete-test-\(UUID().uuidString)",
            fromPubkey: "pk:from",
            toPubkey: "pk:to",
            amountSats: 1500,
            currency: "sats",
            methodId: "lightning",
            description: "Delete test",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            status: .pending,
            direction: .outgoing
        )
        try storage.addRequest(request)
        
        // When - deleting
        try storage.deleteRequest(id: request.id)
        
        // Then - should not be retrievable
        let retrieved = storage.getRequest(id: request.id)
        XCTAssertNil(retrieved)
    }
    
    func testPaymentRequestStorageListRequests() throws {
        // Given - multiple stored requests
        let storage = PaymentRequestStorage(identityName: "test_\(UUID().uuidString)")
        
        for i in 1...3 {
            let request = BitkitPaymentRequest(
                id: "list-test-\(i)-\(UUID().uuidString)",
                fromPubkey: "pk:from\(i)",
                toPubkey: "pk:to\(i)",
                amountSats: Int64(i * 1000),
                currency: "sats",
                methodId: "lightning",
                description: "List test \(i)",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(3600),
                status: .pending,
                direction: .incoming
            )
            try storage.addRequest(request)
        }
        
        // When - listing
        let requests = storage.listRequests()
        
        // Then - should have all requests
        XCTAssertEqual(requests.count, 3)
    }
    
    func testPaymentRequestStoragePendingRequests() throws {
        // Given - requests with different statuses
        let storage = PaymentRequestStorage(identityName: "test_\(UUID().uuidString)")
        
        let pendingRequest = BitkitPaymentRequest(
            id: "pending-\(UUID().uuidString)",
            fromPubkey: "pk:from",
            toPubkey: "pk:to",
            amountSats: 1000,
            currency: "sats",
            methodId: "lightning",
            description: "Pending",
            createdAt: Date(),
            expiresAt: nil,
            status: .pending,
            direction: .incoming
        )
        
        var acceptedRequest = BitkitPaymentRequest(
            id: "accepted-\(UUID().uuidString)",
            fromPubkey: "pk:from",
            toPubkey: "pk:to",
            amountSats: 1000,
            currency: "sats",
            methodId: "lightning",
            description: "Accepted",
            createdAt: Date(),
            expiresAt: nil,
            status: .accepted,
            direction: .outgoing
        )
        
        try storage.addRequest(pendingRequest)
        try storage.addRequest(acceptedRequest)
        
        // When - getting pending requests
        let pending = storage.pendingRequests()
        
        // Then - should only have pending request
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.status, .pending)
    }
    
    func testPaymentRequestStorageUpdateStatus() throws {
        // Given - a stored pending request
        let storage = PaymentRequestStorage(identityName: "test_\(UUID().uuidString)")
        let requestId = "update-\(UUID().uuidString)"
        let request = BitkitPaymentRequest(
            id: requestId,
            fromPubkey: "pk:from",
            toPubkey: "pk:to",
            amountSats: 1000,
            currency: "sats",
            methodId: "lightning",
            description: "Update test",
            createdAt: Date(),
            expiresAt: nil,
            status: .pending,
            direction: .incoming
        )
        try storage.addRequest(request)
        
        // When - updating status
        try storage.updateStatus(id: requestId, status: .accepted)
        
        // Then - status should be updated
        let retrieved = storage.getRequest(id: requestId)
        XCTAssertEqual(retrieved?.status, .accepted)
    }
    
    func testPaymentRequestStoragePendingCount() throws {
        // Given - multiple requests with different statuses
        let storage = PaymentRequestStorage(identityName: "test_\(UUID().uuidString)")
        
        for i in 1...3 {
            let request = BitkitPaymentRequest(
                id: "count-\(i)-\(UUID().uuidString)",
                fromPubkey: "pk:from",
                toPubkey: "pk:to",
                amountSats: 1000,
                currency: "sats",
                methodId: "lightning",
                description: "Count test",
                createdAt: Date(),
                expiresAt: nil,
                status: .pending,
                direction: i % 2 == 0 ? .incoming : .outgoing
            )
            try storage.addRequest(request)
        }
        
        // When - counting pending
        let count = storage.pendingCount()
        
        // Then - should count all pending
        XCTAssertEqual(count, 3)
    }
}
