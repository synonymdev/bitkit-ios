@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class PaykitPaymentProofServiceTests: XCTestCase {
    private let identity = "pubky\(String(repeating: "z", count: 52))"
    private let counterparty = "pubky\(String(repeating: "y", count: 52))"
    private let paymentHash = "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"
    private let preimage = String(repeating: "00", count: 32)

    func testCompletedLightningPaymentRetriesAfterRestart() async throws {
        let record = try paymentRequestRecord()
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        await sdk.setSubmissionFailure(true)

        let service = paymentProofService(sdk: sdk, store: store)
        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        try await service.associateLightningPayment(request, paymentHash: paymentHash)
        await service.completeLightningPayment(paymentHash: paymentHash, preimage: preimage)

        let failedSubmissionCount = await sdk.submissionCount()
        let persistedProof = await store.snapshot().first
        XCTAssertEqual(failedSubmissionCount, 1)
        XCTAssertEqual(persistedProof?.proofData, preimage)

        await sdk.setSubmissionFailure(false)
        let restartedService = paymentProofService(
            sdk: sdk,
            store: store,
            lightningStatus: .succeeded(preimage: preimage)
        )
        await restartedService.reconcile()

        let submittedProof = await sdk.lastSubmission()
        let submission = try XCTUnwrap(submittedProof)
        XCTAssertNil(submission.billingPeriod)
        XCTAssertEqual(submission.paymentEndpointIdentifier, PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue)
        XCTAssertEqual(
            try proofValues(submission.proof.exportText()),
            ["data": preimage, "type": PaykitPaymentProofKind.lightning.rawValue]
        )
        let remainingProofs = await store.snapshot()
        let processCallCount = await sdk.processCallCount()
        XCTAssertTrue(remainingProofs.isEmpty)
        XCTAssertEqual(processCallCount, 1)
    }

    func testMismatchedLightningPreimageIsNotSubmitted() async throws {
        let record = try paymentRequestRecord()
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        try await service.associateLightningPayment(request, paymentHash: paymentHash)
        await service.completeLightningPayment(paymentHash: paymentHash, preimage: String(repeating: "01", count: 32))

        let submissionCount = await sdk.submissionCount()
        let persistedProof = await store.snapshot().first
        XCTAssertEqual(submissionCount, 0)
        XCTAssertNil(persistedProof?.proofData)
    }

    func testExistingProofSuppressesDuplicateSubmission() async throws {
        let proof = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            data: preimage
        )
        let record = try paymentRequestRecord(paymentProofs: [proof])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        try await service.associateLightningPayment(request, paymentHash: paymentHash)
        await service.completeLightningPayment(paymentHash: paymentHash, preimage: preimage)

        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    func testFailedLightningPaymentClearsCorrelation() async throws {
        let record = try paymentRequestRecord()
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        try await service.associateLightningPayment(request, paymentHash: paymentHash)
        await service.failLightningPayment(paymentHash: paymentHash)

        let remainingProofs = await store.snapshot()
        let submissionCount = await sdk.submissionCount()
        XCTAssertTrue(remainingProofs.isEmpty)
        XCTAssertEqual(submissionCount, 0)
    }

    func testOnchainPaymentSubmitsTransactionIdForSelectedEndpoint() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)

        let submittedProof = await sdk.lastSubmission()
        let submission = try XCTUnwrap(submittedProof)
        XCTAssertEqual(submission.paymentEndpointIdentifier, endpoint)
        XCTAssertEqual(
            try proofValues(submission.proof.exportText()),
            ["data": txid, "type": PaykitPaymentProofKind.onchain.rawValue]
        )
        let remainingProofs = await store.snapshot()
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    func testLightningRetryPreservesEarlierPaymentCorrelation() async throws {
        let record = try paymentRequestRecord()
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        try await service.associateLightningPayment(request, paymentHash: paymentHash)
        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        try await service.associateLightningPayment(request, paymentHash: String(repeating: "aa", count: 32))

        await service.completeLightningPayment(paymentHash: paymentHash, preimage: preimage)

        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    func testClearedStoreDoesNotRestoreCachedProofs() async throws {
        let firstRecord = try paymentRequestRecord()
        let firstRequest = try XCTUnwrap(PaykitPaymentRequest(record: firstRecord, now: Date()))
        let secondRequestId = "550e8400-e29b-41d4-a716-446655440001"
        let secondRecord = try paymentRequestRecord(paymentRequestId: secondRequestId)
        let secondRequest = try XCTUnwrap(PaykitPaymentRequest(record: secondRecord, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [firstRecord, secondRecord])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(
            request: firstRequest,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        await store.clear()
        try await service.prepare(
            request: secondRequest,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )

        let remainingProofs = await store.snapshot()
        XCTAssertEqual(remainingProofs.count, 1)
        XCTAssertEqual(remainingProofs.first?.requestId.paymentRequestId, secondRequestId)
    }

    func testOnchainPaymentSubmitsWhenCompletedProofCannotBePersisted() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        await store.failNextSave()
        await service.completeOnchainPayment(
            request,
            txid: String(repeating: "ab", count: 32),
            paymentEndpointIdentifier: endpoint
        )

        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    func testOnchainPaymentSubmitsWhenPreparedProofCannotBeLoaded() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        await store.failNextLoad()
        await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)

        let submittedProof = await sdk.lastSubmission()
        let submission = try XCTUnwrap(submittedProof)
        XCTAssertEqual(submission.paymentEndpointIdentifier, endpoint)
        XCTAssertEqual(
            try proofValues(submission.proof.exportText()),
            ["data": txid, "type": PaykitPaymentProofKind.onchain.rawValue]
        )
        let remainingProofs = await store.snapshot()
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    private func paymentProofService(
        sdk: PaymentProofSdkMock,
        store: PaymentProofMemoryStore,
        lightningStatus: PaykitLightningPaymentProofStatus = .unknown
    ) -> PaykitPaymentProofService {
        PaykitPaymentProofService(
            sdk: sdk,
            store: store,
            lightningPaymentLookup: PaymentProofLightningLookup(status: lightningStatus),
            logInfo: { _ in },
            logWarning: { _ in }
        )
    }

    private func paymentRequestRecord(
        endpoints: [String] = [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
        paymentProofs: [PaymentProofRecord] = [],
        paymentRequestId: String = "550e8400-e29b-41d4-a716-446655440000"
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            paymentRequestId: paymentRequestId,
            localRole: .payer,
            state: .proposed,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.00001", asset: "btc"),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: endpoints,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            paymentProofs: paymentProofs,
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
    }

    private func paymentProofRecord(
        endpoint: String,
        kind: PaykitPaymentProofKind,
        data: String
    ) throws -> PaymentProofRecord {
        try PaymentProofRecord(
            eventId: "750e8400-e29b-41d4-a716-446655440000",
            outboundMessageId: nil,
            outboundStatus: nil,
            streamItemId: 2,
            paymentReference: PaymentReference(text: "invoice-123"),
            billingPeriod: nil,
            paymentEndpointIdentifier: endpoint,
            proof: PrivateJsonObject(text: "{\"data\":\"\(data)\",\"type\":\"\(kind.rawValue)\"}"),
            recordedAt: "2027-01-15T08:01:00Z"
        )
    }

    private func proofValues(_ text: String) throws -> [String: String] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}

private actor PaymentProofMemoryStore: PaykitPaymentProofStoring {
    private var proofs: [PendingPaykitPaymentProof] = []
    private var shouldFailNextLoad = false
    private var shouldFailNextSave = false

    func load() throws -> [PendingPaykitPaymentProof] {
        if shouldFailNextLoad {
            shouldFailNextLoad = false
            throw PaymentProofStoreMockError.load
        }
        return proofs
    }

    func save(_ proofs: [PendingPaykitPaymentProof]) throws {
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw PaymentProofStoreMockError.save
        }
        self.proofs = proofs
    }

    func clear() {
        proofs = []
    }

    func failNextSave() {
        shouldFailNextSave = true
    }

    func failNextLoad() {
        shouldFailNextLoad = true
    }

    func snapshot() -> [PendingPaykitPaymentProof] {
        proofs
    }
}

private struct PaymentProofLightningLookup: PaykitLightningPaymentProofLookingUp {
    let status: PaykitLightningPaymentProofStatus

    func status(paymentHash _: String) async -> PaykitLightningPaymentProofStatus {
        status
    }
}

private actor PaymentProofSdkMock: PaykitPaymentProofSdkHandling {
    private let identity: String
    private var records: [PaymentRequestRecord]
    private var submissions: [PaymentProofSubmission] = []
    private var shouldFailSubmission = false
    private var privateMessageProcessCallCount = 0

    init(identity: String, records: [PaymentRequestRecord]) {
        self.identity = identity
        self.records = records
    }

    func identityStatus() -> IdentityStatus? {
        IdentityStatus(publicKey: identity, liveSessionAvailable: true)
    }

    func paymentRequests() -> [PaymentRequestRecord] {
        records
    }

    func processPendingPrivateMessages() -> [OutboundPrivateCounterpartySendReport] {
        privateMessageProcessCallCount += 1
        return []
    }

    func submitPaymentProof(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String,
        proof: PaymentProofSubmission
    ) throws -> PaymentRequestRecord {
        submissions.append(proof)
        if shouldFailSubmission {
            throw PaymentProofSdkMockError.submission
        }

        guard let index = records.firstIndex(where: {
            $0.counterparty == counterparty &&
                $0.counterpartyReceiverPath == counterpartyReceiverPath &&
                $0.paymentRequestId == paymentRequestId
        }), let paymentReference = records[index].terms?.paymentReference else {
            throw PaymentProofSdkMockError.requestMissing
        }
        records[index].paymentProofs.append(PaymentProofRecord(
            eventId: UUID().uuidString,
            outboundMessageId: 1,
            outboundStatus: .pending,
            streamItemId: nil,
            paymentReference: paymentReference,
            billingPeriod: proof.billingPeriod,
            paymentEndpointIdentifier: proof.paymentEndpointIdentifier,
            proof: proof.proof,
            recordedAt: "2027-01-15T08:01:00Z"
        ))
        return records[index]
    }

    func setSubmissionFailure(_ value: Bool) {
        shouldFailSubmission = value
    }

    func submissionCount() -> Int {
        submissions.count
    }

    func lastSubmission() -> PaymentProofSubmission? {
        submissions.last
    }

    func processCallCount() -> Int {
        privateMessageProcessCallCount
    }
}

private enum PaymentProofSdkMockError: Error {
    case requestMissing
    case submission
}

private enum PaymentProofStoreMockError: Error {
    case load
    case save
}
