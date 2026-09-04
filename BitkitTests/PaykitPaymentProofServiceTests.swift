@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class PaykitPaymentProofServiceTests: XCTestCase {
    private let identity = "pubky\(String(repeating: "z", count: 52))"
    private let counterparty = "pubky\(String(repeating: "y", count: 52))"
    private let paymentHash = "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"
    private let preimage = String(repeating: "00", count: 32)
    private let onchainAddress = "bcrt1qpaymentproof"

    func testSubscriptionHistoryKeepsPaymentProofKind() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let billingPeriod = BillingPeriod(
            startsAt: "2027-01-01T08:00:00.000Z",
            endsAt: "2027-02-01T08:00:00.000Z"
        )
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))
        let through = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let cases: [(PublicPaykitService.MethodId, PaykitPaymentProofKind)] = [
            (.bitcoinLightningBolt11, .lightning),
            (.regtestOnchainP2wpkh, .onchain),
        ]

        for (method, proofKind) in cases {
            let proof = try paymentProofRecord(
                endpoint: method.rawValue,
                kind: proofKind,
                data: String(repeating: "01", count: 32),
                billingPeriod: billingPeriod
            )
            let record = try paymentRequestRecord(
                endpoints: [method.rawValue],
                paymentProofs: [proof],
                state: .activeRecurring,
                recurrence: recurrence
            )
            let subscription = try XCTUnwrap(PaykitSubscription(record: record))
            let request = try XCTUnwrap(subscription.requests(through: through, acceptedAt: acceptedAt).first)

            XCTAssertEqual(request.lifecycleState, .proofSubmitted)
            XCTAssertEqual(request.paymentProofKind, proofKind)
        }
    }

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
        let completedProofKinds = await service.completedRequestProofKindsAwaitingSubmission(identity: identity)
        XCTAssertEqual(failedSubmissionCount, 1)
        XCTAssertEqual(persistedProof?.proofData, preimage)
        XCTAssertEqual(completedProofKinds, [request.id: .lightning])

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

    func testCanceledLightningWaitPreservesCorrelationForLaterSettlement() async throws {
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
        await service.cancelPreparation(request)

        let correlatedProof = await store.snapshot().first
        XCTAssertEqual(correlatedProof?.paymentIdentifier, paymentHash)

        await service.completeLightningPayment(paymentHash: paymentHash, preimage: preimage)

        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    func testUnstartedSubscriptionPreparationIsDiscardedBeforeCancellation() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let request = try XCTUnwrap(subscription.paymentDueOnAcceptance(at: now))
        let store = PaymentProofMemoryStore()
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [record]),
            store: store
        )

        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )

        let protectedRequestIds = try await service.protectedRequestIdsForSubscriptionCancellation(
            identity: identity,
            subscriptionId: subscription.id
        )
        XCTAssertTrue(protectedRequestIds.isEmpty)
        let remainingProofs = await store.snapshot()
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    func testStartedSubscriptionPaymentIsProtectedFromCancellation() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint], state: .activeRecurring, recurrence: recurrence)
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let request = try XCTUnwrap(subscription.paymentDueOnAcceptance(at: now))
        let store = PaymentProofMemoryStore()
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [record]),
            store: store
        )
        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)

        let protectedRequestIds = try await service.protectedRequestIdsForSubscriptionCancellation(
            identity: identity,
            subscriptionId: subscription.id
        )

        XCTAssertEqual(protectedRequestIds, [request.id])
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(remainingProofs.map(\.requestId), [request.id])
    }

    func testCancelPreparationDoesNotRemoveAnotherIdentityProof() async throws {
        let record = try paymentRequestRecord()
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let otherIdentityProof = PendingPaykitPaymentProof(
            identity: "pubky\(String(repeating: "x", count: 52))",
            requestId: request.id,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            paymentIdentifier: nil,
            proofData: nil
        )
        await store.seed([otherIdentityProof])
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [record]),
            store: store
        )

        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        await service.cancelPreparation(request)

        let remainingProofs = await store.snapshot()
        XCTAssertEqual(remainingProofs, [otherIdentityProof])
    }

    func testOnchainPaymentSubmitsTransactionIdForSelectedEndpoint() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let proofRemoved = expectation(description: "On-chain proof removed after submission")
        let store = PaymentProofMemoryStore { proofs in
            if proofs.isEmpty {
                proofRemoved.fulfill()
            }
        }
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        let inFlightRequestIds = await service.inFlightRequestIds(identity: identity)
        XCTAssertEqual(inFlightRequestIds, [request.id])
        await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
        await sdk.waitForSubmissionStart()
        await fulfillment(of: [proofRemoved], timeout: 1)

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

    func testOnchainCompletionDoesNotWaitForProofDelivery() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)
        let completion = expectation(description: "On-chain proof state persisted")

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await sdk.suspendSubmission()
        let completionTask = Task {
            await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 1)
        await sdk.waitForSubmissionStart()

        let persistedProof = await store.snapshot().first
        XCTAssertEqual(persistedProof?.paymentIdentifier, txid)
        XCTAssertEqual(persistedProof?.proofData, txid)

        await sdk.resumeSubmission()
        await completionTask.value
    }

    func testStartedOnchainPaymentSurvivesPreparationCancellation() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let service = paymentProofService(sdk: PaymentProofSdkMock(identity: identity, records: [record]), store: store)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await service.cancelPreparation(request)

        let storedProofs = await store.snapshot()
        let proof = try XCTUnwrap(storedProofs.first)
        XCTAssertTrue(proof.paymentStarted)
    }

    func testUncertainOnchainPaymentReconcilesFromPrivateDestination() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(
            endpoints: [endpoint],
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440099"
        )
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let proofRemoved = expectation(description: "On-chain proof removed after submission")
        let store = PaymentProofMemoryStore { proofs in
            if proofs.isEmpty {
                proofRemoved.fulfill()
            }
        }
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let txid = String(repeating: "ab", count: 32)
        let service = paymentProofService(sdk: sdk, store: store, onchainTxids: [txid])
        let resolutionExpectation = expectation(description: "On-chain payment resolution published")
        let resolution = PaykitPaymentProofService.onchainPaymentResolutionPublisher
            .filter { $0.requestId == request.id }
            .first()
            .sink {
                XCTAssertEqual($0.identity, self.identity)
                XCTAssertEqual($0.transactionId, txid)
                resolutionExpectation.fulfill()
            }

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await service.reconcile()
        await sdk.waitForSubmissionStart()
        await fulfillment(of: [resolutionExpectation, proofRemoved], timeout: 1)
        withExtendedLifetime(resolution) {}

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

    func testUncertainOnchainPaymentDoesNotReuseTransactionFromBeforeAttempt() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let oldTransactionId = String(repeating: "ab", count: 32)
        let service = paymentProofService(
            sdk: sdk,
            store: store,
            onchainTxids: [oldTransactionId],
            existingOnchainTxids: [oldTransactionId]
        )

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await service.reconcile()

        let submissionCount = await sdk.submissionCount()
        let storedProofs = await store.snapshot()
        let storedProof = try XCTUnwrap(storedProofs.first)
        XCTAssertEqual(submissionCount, 0)
        XCTAssertNil(storedProof.proofData)
        XCTAssertEqual(storedProof.onchainMatchingTransactionIdsBeforeAttempt, [oldTransactionId])
    }

    func testReconcileContinuesAfterOnchainLookupFailure() async throws {
        let onchainEndpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let lightningEndpoint = PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
        let onchainRecord = try paymentRequestRecord(
            endpoints: [onchainEndpoint],
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440001"
        )
        let lightningRecord = try paymentRequestRecord(
            endpoints: [lightningEndpoint],
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440002"
        )
        let onchainRequest = try XCTUnwrap(PaykitPaymentRequest(record: onchainRecord, now: Date()))
        let lightningRequest = try XCTUnwrap(PaykitPaymentRequest(record: lightningRecord, now: Date()))
        let onchainProof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: onchainRequest.id,
            paymentEndpointIdentifier: onchainEndpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: nil,
            proofData: nil,
            onchainAddress: onchainAddress,
            onchainAmountSats: onchainRequest.amountSats,
            onchainMatchingTransactionIdsBeforeAttempt: []
        )
        let lightningProof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: lightningRequest.id,
            paymentEndpointIdentifier: lightningEndpoint,
            kind: .lightning,
            paymentStarted: true,
            paymentIdentifier: paymentHash,
            proofData: nil
        )
        let store = PaymentProofMemoryStore()
        await store.seed([onchainProof, lightningProof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [onchainRecord, lightningRecord])
        let service = paymentProofService(
            sdk: sdk,
            store: store,
            lightningStatus: .succeeded(preimage: preimage),
            onchainLookupFails: true
        )

        await service.reconcile()

        let submissionCount = await sdk.submissionCount()
        let submittedEndpoint = await sdk.lastSubmission()?.paymentEndpointIdentifier
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(submittedEndpoint, lightningEndpoint)
        XCTAssertEqual(remainingProofs, [onchainProof])
    }

    func testDefiniteOnchainFailureClearsStartedProof() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let service = paymentProofService(sdk: PaymentProofSdkMock(identity: identity, records: [record]), store: store)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await service.failOnchainPayment(request)

        let storedProofs = await store.snapshot()
        XCTAssertTrue(storedProofs.isEmpty)
    }

    func testOnchainFailureClearsStartedProofWithoutLiveIdentity() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await sdk.setIdentityAvailable(false)

        await service.failOnchainPayment(request)

        let storedProofs = await store.snapshot()
        XCTAssertTrue(storedProofs.isEmpty)
    }

    func testCancelPreparationClearsProofWithoutLiveIdentity() async throws {
        let endpoint = PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .lightning)
        await sdk.setIdentityAvailable(false)

        await service.cancelPreparation(request)

        let storedProofs = await store.snapshot()
        XCTAssertTrue(storedProofs.isEmpty)
    }

    func testRecurringPaymentSubmitsExactBillingPeriod() async throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let request = try XCTUnwrap(subscription.requests(through: acceptedAt, acceptedAt: acceptedAt).first)
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

        let submittedProof = await sdk.lastSubmission()
        let submission = try XCTUnwrap(submittedProof)
        XCTAssertEqual(submission.billingPeriod?.startsAt, "2027-01-01T08:00:00Z")
        XCTAssertEqual(submission.billingPeriod?.endsAt, "2027-02-01T08:00:00Z")
    }

    func testProofFromEarlierBillingPeriodDoesNotSuppressRecurringPayment() async throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let previousProof = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            data: String(repeating: "01", count: 32),
            billingPeriod: BillingPeriod(startsAt: "2027-01-01T08:00:00.000Z", endsAt: "2027-02-01T08:00:00.000Z")
        )
        let record = try paymentRequestRecord(
            paymentProofs: [previousProof],
            state: .activeRecurring,
            recurrence: recurrence
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-15T08:00:00Z"))
        let request = try XCTUnwrap(subscription.requests(through: date, acceptedAt: date).last)
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
        let submission = await sdk.lastSubmission()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(submission?.billingPeriod?.startsAt, "2027-02-01T08:00:00Z")
    }

    func testLightningRetryIsRejectedWhileEarlierPaymentIsUnresolved() async throws {
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
        do {
            try await service.prepare(
                request: request,
                paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                kind: .lightning
            )
            XCTFail("Expected a second unresolved payment attempt to be rejected")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
        }

        let remainingProofs = await store.snapshot()
        XCTAssertEqual(remainingProofs.count, 1)
        XCTAssertEqual(remainingProofs.first?.paymentIdentifier, paymentHash)

        await service.failLightningPayment(paymentHash: paymentHash)
        try await service.prepare(
            request: request,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        let retryProofs = await store.snapshot()
        XCTAssertEqual(retryProofs.count, 1)
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
        let proofRemoved = expectation(description: "On-chain proof removed after submission")
        let store = PaymentProofMemoryStore { proofs in
            if proofs.isEmpty {
                proofRemoved.fulfill()
            }
        }
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await store.failNextSave()
        await service.completeOnchainPayment(
            request,
            txid: String(repeating: "ab", count: 32),
            paymentEndpointIdentifier: endpoint
        )
        await sdk.waitForSubmissionStart()
        await fulfillment(of: [proofRemoved], timeout: 1)

        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 1)
        XCTAssertTrue(remainingProofs.isEmpty)
    }

    func testCompletedOnchainProofRemainsDurableWhenPersistenceAndSubmissionInitiallyFail() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await store.failNextSave()
        await sdk.setSubmissionFailure(true)
        await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
        await sdk.waitForSubmissionStart()

        let storedProofs = await store.snapshot()
        let proof = try XCTUnwrap(storedProofs.first)
        XCTAssertEqual(proof.proofData, txid)
        let submissionCount = await sdk.submissionCount()
        XCTAssertEqual(submissionCount, 1)
    }

    func testOnchainPaymentSubmitsWhenPreparedProofCannotBeLoaded() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let proofRemoved = expectation(description: "On-chain proof removed after submission")
        let store = PaymentProofMemoryStore { proofs in
            if proofs.isEmpty {
                proofRemoved.fulfill()
            }
        }
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await store.failNextLoad()
        await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
        await sdk.waitForSubmissionStart()
        await fulfillment(of: [proofRemoved], timeout: 1)

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

    func testReconcileWithoutPendingProofsSkipsSdk() async {
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [])
        let service = paymentProofService(sdk: sdk, store: store)

        await service.reconcile()

        let identityStatusCallCount = await sdk.identityStatusCallCount()
        XCTAssertEqual(identityStatusCallCount, 0)
    }

    private func paymentProofService(
        sdk: PaymentProofSdkMock,
        store: PaymentProofMemoryStore,
        lightningStatus: PaykitLightningPaymentProofStatus = .unknown,
        onchainTxids: [String] = [],
        existingOnchainTxids: Set<String> = [],
        onchainLookupFails: Bool = false
    ) -> PaykitPaymentProofService {
        PaykitPaymentProofService(
            sdk: sdk,
            store: store,
            lightningPaymentLookup: PaymentProofLightningLookup(status: lightningStatus),
            onchainPaymentLookup: PaymentProofOnchainLookup(
                transactionIds: onchainTxids,
                existingTransactionIds: existingOnchainTxids,
                transactionLookupFails: onchainLookupFails
            ),
            logInfo: { _ in },
            logWarning: { _ in }
        )
    }

    private func paymentRequestRecord(
        endpoints: [String] = [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
        paymentProofs: [PaymentProofRecord] = [],
        paymentRequestId: String = "550e8400-e29b-41d4-a716-446655440000",
        state: PaymentRequestLifecycleState = .proposed,
        recurrence: PaymentRequestRecurrence? = nil
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            paymentRequestId: paymentRequestId,
            localRole: .payer,
            state: state,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.00001", asset: "btc"),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: recurrence,
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
        data: String,
        billingPeriod: BillingPeriod? = nil
    ) throws -> PaymentProofRecord {
        try PaymentProofRecord(
            eventId: "750e8400-e29b-41d4-a716-446655440000",
            outboundMessageId: nil,
            outboundStatus: nil,
            streamItemId: 2,
            paymentReference: PaymentReference(text: "invoice-123"),
            billingPeriod: billingPeriod,
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
    private let onSave: @Sendable ([PendingPaykitPaymentProof]) -> Void

    init(onSave: @escaping @Sendable ([PendingPaykitPaymentProof]) -> Void = { _ in }) {
        self.onSave = onSave
    }

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
        onSave(proofs)
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

    func seed(_ proofs: [PendingPaykitPaymentProof]) {
        self.proofs = proofs
    }
}

private struct PaymentProofLightningLookup: PaykitLightningPaymentProofLookingUp {
    let status: PaykitLightningPaymentProofStatus

    func status(paymentHash _: String) async -> PaykitLightningPaymentProofStatus {
        status
    }
}

private struct PaymentProofOnchainLookup: PaykitOnchainPaymentProofLookingUp {
    let transactionIds: [String]
    let existingTransactionIds: Set<String>
    let transactionLookupFails: Bool

    func existingTransactionIds(address _: String, amountSats _: UInt64) async throws -> Set<String> {
        existingTransactionIds
    }

    func transactionId(address _: String, amountSats _: UInt64, excluding transactionIds: Set<String>) async throws -> String? {
        if transactionLookupFails {
            throw PaymentProofLookupMockError.transactionLookup
        }
        return self.transactionIds.first { !transactionIds.contains($0) }
    }
}

private actor PaymentProofSdkMock: PaykitPaymentProofSdkHandling {
    private let identity: String
    private var records: [PaymentRequestRecord]
    private var submissions: [PaymentProofSubmission] = []
    private var shouldFailSubmission = false
    private var privateMessageProcessCallCount = 0
    private var identityStatusCalls = 0
    private var isIdentityAvailable = true
    private var shouldSuspendSubmission = false
    private var submissionContinuation: CheckedContinuation<Void, Never>?
    private var submissionStartContinuations: [CheckedContinuation<Void, Never>] = []

    init(identity: String, records: [PaymentRequestRecord]) {
        self.identity = identity
        self.records = records
    }

    func identityStatus() -> IdentityStatus? {
        identityStatusCalls += 1
        guard isIdentityAvailable else { return nil }
        return IdentityStatus(publicKey: identity, liveSessionAvailable: true)
    }

    func setIdentityAvailable(_ isAvailable: Bool) {
        isIdentityAvailable = isAvailable
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
    ) async throws -> PaymentRequestRecord {
        submissions.append(proof)
        submissionStartContinuations.forEach { $0.resume() }
        submissionStartContinuations.removeAll()
        if shouldSuspendSubmission {
            await withCheckedContinuation { continuation in
                submissionContinuation = continuation
            }
        }
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

    func suspendSubmission() {
        shouldSuspendSubmission = true
    }

    func resumeSubmission() {
        shouldSuspendSubmission = false
        submissionContinuation?.resume()
        submissionContinuation = nil
    }

    func waitForSubmissionStart() async {
        guard submissions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            submissionStartContinuations.append(continuation)
        }
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

    func identityStatusCallCount() -> Int {
        identityStatusCalls
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

private enum PaymentProofLookupMockError: Error {
    case transactionLookup
}
