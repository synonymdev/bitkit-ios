@testable import Bitkit
import LDKNode
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
            let request = try XCTUnwrap(
                subscription.requests(through: through, acceptedAt: PaykitPreciseInstant(date: acceptedAt)).first
            )

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

        await store.seed([PendingPaykitPaymentProof(
            identity: identity, requestId: request.id,
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning, paymentStarted: true, paymentIdentifier: paymentHash, proofData: preimage
        )])
        await service.reconcile()

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

    func testUncertainLightningSubmissionPreservesProofUntilSettlement() async throws {
        let errors: [Error] = [
            NodeError.PersistenceFailed(message: "io"),
            Bitkit.AppError(error: NodeError.PersistenceFailed(message: "io")),
            NodeError.DuplicatePayment(message: "pending"),
            NSError(domain: "payment", code: 1),
        ]
        for error in errors {
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

            let failed = await service.failLightningPayment(paymentHash: paymentHash, submissionError: error)
            await service.cancelPreparation(request)
            let restartedService = paymentProofService(sdk: sdk, store: store)
            await restartedService.reconcile()

            let inFlight = await restartedService.inFlightRequestIds(identity: identity)
            XCTAssertFalse(failed)
            XCTAssertEqual(inFlight, [request.id])
            let proof = await store.snapshot().first
            XCTAssertEqual(proof?.paymentIdentifier, paymentHash)

            await restartedService.completeLightningPayment(paymentHash: paymentHash, preimage: preimage)
            let remainingProofs = await store.snapshot()
            let submissionCount = await sdk.submissionCount()
            XCTAssertTrue(remainingProofs.isEmpty)
            XCTAssertEqual(submissionCount, 1)
        }
    }

    func testDefiniteLightningSubmissionFailureClearsProof() async throws {
        let errors: [Error] = [
            Bitkit.CustomServiceError.nodeNotSetup,
            Bitkit.AppError(serviceError: .nodeNotStarted),
            NodeError.NotRunning(message: "stopped"),
            NodeError.InvalidInvoice(message: "invalid"),
            NodeError.InvalidAmount(message: "invalid"),
            Bitkit.AppError(error: NodeError.PaymentSendingFailed(message: "no route")),
        ]
        for error in errors {
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

            let failed = await service.failLightningPayment(paymentHash: paymentHash, submissionError: error)

            let remainingProofs = await store.snapshot()
            XCTAssertTrue(failed, "\(error)")
            XCTAssertTrue(remainingProofs.isEmpty, "\(error)")
        }
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
        XCTAssertEqual(persistedProof?.onchainBroadcastAccepted, true)

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

    func testUncertainOnchainPaymentDoesNotReconcileByDestinationAndAmount() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(
            endpoints: [endpoint],
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440099"
        )
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await service.reconcile()
        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(remainingProofs.first?.paymentStarted, true)
        XCTAssertNil(remainingProofs.first?.proofData)
    }

    func testUncertainOnchainPaymentDoesNotReuseTransactionFromBeforeAttempt() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await service.reconcile()

        let submissionCount = await sdk.submissionCount()
        let storedProofs = await store.snapshot()
        let storedProof = try XCTUnwrap(storedProofs.first)
        XCTAssertEqual(submissionCount, 0)
        XCTAssertNil(storedProof.proofData)
        XCTAssertNil(storedProof.onchainMatchingTransactionIdsBeforeAttempt)
    }

    func testAcceptedAttemptReconcilesExactTransactionId() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let attempts = OnchainSendAttemptService(store: MemoryAttemptStore())
        let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
        let txid = String(repeating: "ab", count: 32)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        let attemptId = try await attempts.admit(
            walletId: "node-0", requestId: request.id, orderId: nil,
            address: onchainAddress, amountSats: request.amountSats, isMaxAmount: false
        )
        try await attempts.record(.accepted(txid: txid), attemptId: attemptId)
        await service.reconcile()
        await sdk.waitForSubmissionStart()

        let submittedProof = await sdk.lastSubmission()
        let submission = try XCTUnwrap(submittedProof)
        XCTAssertEqual(
            try proofValues(submission.proof.exportText()),
            ["data": txid, "type": PaykitPaymentProofKind.onchain.rawValue]
        )
    }

    func testAcceptedResultStorageFailureStillCompletesProofWithExactTxid() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let attemptStore = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: attemptStore)
        let proofStore = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: proofStore, attemptService: attempts)
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        _ = try await attempts.send(
            using: node, address: onchainAddress, amountSats: request.amountSats,
            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false, requestId: request.id
        ) {
            try await service.markOnchainPaymentStarted(request, address: self.onchainAddress)
            attemptStore.failSave = true
        }
        await service.reconcile()
        await sdk.waitForSubmissionStart()
        let submitted = await sdk.lastSubmission()
        XCTAssertEqual(try proofValues(XCTUnwrap(submitted).proof.exportText()), ["data": txid, "type": PaykitPaymentProofKind.onchain.rawValue])
        XCTAssertEqual(node.calls, 1)
        XCTAssertEqual(attemptStore.snapshot().first?.status, .pending)
        XCTAssertNil(attemptStore.snapshot().first?.txid)
        attemptStore.failSave = false
        let restarted = OnchainSendAttemptService(store: attemptStore)
        let knownAfterRestart = try await restarted.acceptedTransactionId(for: request.id)
        XCTAssertNil(knownAfterRestart)
        do {
            _ = try await restarted.send(
                using: node, address: onchainAddress, amountSats: request.amountSats,
                satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false, requestId: request.id
            )
            XCTFail("Restart repaid accepted request after result save failure")
        } catch {}
        XCTAssertEqual(node.calls, 1)
    }

    func testFailedProofPersistenceRetainsAcceptedPriorResultForLocalRetry() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let attemptStore = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: attemptStore)
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        _ = try await attempts.send(
            using: node, address: onchainAddress, amountSats: request.amountSats,
            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: true, requestId: request.id
        ) { try await service.markOnchainPaymentStarted(request, address: self.onchainAddress) }
        await store.failNextSave()
        let saved = await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
        XCTAssertFalse(saved)
        XCTAssertEqual(attemptStore.snapshot().first?.status, .accepted)
        XCTAssertEqual(attemptStore.snapshot().first?.localFollowupComplete, false)
        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        let resumed = try await attempts.send(
            using: node, address: onchainAddress, amountSats: request.amountSats,
            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: true, requestId: request.id
        )
        XCTAssertEqual(resumed, .accepted(txid: txid))
        let retrySaved = await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
        XCTAssertTrue(retrySaved)
        XCTAssertEqual(node.calls, 1)
    }

    func testOlderPaidRequestCannotSwitchMethodAfterGuardIsReplaced() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let txid = String(repeating: "ab", count: 32)
        let remoteProof = try paymentProofRecord(endpoint: endpoint, kind: .onchain, data: txid)
        let paidRecord = try paymentRequestRecord(
            endpoints: [endpoint, PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
            paymentProofs: [remoteProof],
            state: .proofSubmitted
        )
        let request = try XCTUnwrap(PaykitPaymentRequest(
            record: paymentRequestRecord(endpoints: [endpoint, PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue]),
            now: Date()
        ))
        let attemptStore = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: attemptStore)
        let id = try await attempts.admit(
            walletId: "node-0",
            requestId: request.id,
            orderId: nil,
            address: onchainAddress,
            amountSats: request.amountSats,
            isMaxAmount: false
        )
        try await attempts.record(.accepted(txid: txid), attemptId: id)
        try await attempts.acknowledgeLocalFollowup(txid: txid)
        _ = try await attempts.admit(walletId: "node-0", requestId: nil, orderId: nil, address: onchainAddress, amountSats: 1000, isMaxAmount: false)
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [paidRecord]),
            store: PaymentProofMemoryStore(),
            attemptService: attempts
        )
        do {
            try await service.prepare(
                request: request,
                paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                kind: .lightning
            )
            XCTFail("Older paid request bypassed existing SDK record")
        } catch let error as PaykitPaymentRequestError {
            XCTAssertEqual(error, .operationInProgress)
        }
        XCTAssertEqual(attemptStore.snapshot().count, 1)
    }

    func testUndecodableProofStoreIsPreservedAndBlocksDispatch() async throws {
        guard Env.isUnitTest else { throw XCTSkip("Requires isolated unit-test Keychain namespace") }
        let key = KeychainEntryType.paykitPendingPaymentProofs
        let original = try Keychain.load(key: key)
        defer {
            if let original {
                try? Keychain.upsert(key: key, data: original)
            } else {
                try? Keychain.delete(key: key)
            }
        }
        let corrupt = Data("{broken proof state".utf8)
        try Keychain.upsert(key: key, data: corrupt)
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let attempts = OnchainSendAttemptService(store: MemoryAttemptStore())
        let service = PaykitPaymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [record]),
            store: PaykitPaymentProofStore(),
            attemptService: attempts,
            logInfo: { _ in },
            logWarning: { _ in }
        )
        do { _ = try await PaykitPaymentProofStore().load(); XCTFail("Corrupt proofs decoded as empty") } catch {}
        do {
            try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
            XCTFail("Corrupt proof state allowed preparation")
        } catch {}
        let node = AttemptNodeMock(result: .accepted(txid: String(repeating: "ab", count: 32)))
        do {
            _ = try await attempts.send(
                using: node,
                address: onchainAddress,
                amountSats: 1000,
                satsPerVbyte: 1,
                utxosToSpend: nil,
                isMaxAmount: false,
                requestId: request.id
            ) {
                try await service.markOnchainPaymentStarted(request, address: self.onchainAddress)
            }
            XCTFail("Corrupt proof state allowed dispatch")
        } catch {}
        XCTAssertEqual(node.calls, 0)
        XCTAssertEqual(try Keychain.load(key: key), corrupt)
    }

    func testLegacyOnchainTxidWithoutAcceptanceEvidenceIsNotSubmitted() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        let legacyProof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: txid,
            proofData: txid,
            onchainAddress: onchainAddress,
            onchainAmountSats: request.amountSats,
            onchainMatchingTransactionIdsBeforeAttempt: []
        )
        let store = PaymentProofMemoryStore()
        await store.seed([legacyProof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        await service.reconcile()

        let submissionCount = await sdk.submissionCount()
        let storedProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(storedProofs, [legacyProof])
        let completedKinds = await service.completedRequestProofKindsAwaitingSubmission(identity: identity)
        XCTAssertTrue(completedKinds.isEmpty)
    }

    func testPendingOnchainAttemptBlocksLightningMethodSwitch() async throws {
        let onchainEndpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let lightningEndpoint = PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
        let record = try paymentRequestRecord(endpoints: [onchainEndpoint, lightningEndpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let attempts = OnchainSendAttemptService(store: MemoryAttemptStore())
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [record]),
            store: PaymentProofMemoryStore(),
            attemptService: attempts
        )

        try await service.prepare(request: request, paymentEndpointIdentifier: onchainEndpoint, kind: .onchain)
        _ = try await attempts.admit(
            walletId: "node-0", requestId: request.id, orderId: nil,
            address: onchainAddress, amountSats: request.amountSats, isMaxAmount: false
        )
        do {
            try await service.prepare(request: request, paymentEndpointIdentifier: lightningEndpoint, kind: .lightning)
            XCTFail("Lightning method switch bypassed the on-chain attempt")
        } catch let error as PaykitPaymentRequestError {
            XCTAssertEqual(error, .operationInProgress)
        }
    }

    func testAttemptReadFailureBlocksShopPreparation() async throws {
        let record = try paymentRequestRecord()
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let attemptStore = MemoryAttemptStore()
        attemptStore.failLoad = true
        let proofStore = PaymentProofMemoryStore()
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [record]),
            store: proofStore,
            attemptService: OnchainSendAttemptService(store: attemptStore)
        )

        do {
            try await service.prepare(
                request: request,
                paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                kind: .lightning
            )
            XCTFail("Shop preparation continued after an attempt-store read failure")
        } catch {}
        let proofs = await proofStore.snapshot()
        XCTAssertTrue(proofs.isEmpty)
    }

    func testForeignWalletOnchainProofStaysInertAndBlocksDuplicatePayment() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: nil,
            proofData: nil,
            onchainAddress: onchainAddress,
            onchainAmountSats: request.amountSats,
            onchainWalletId: "trezor:android",
            onchainMatchingTransactionIdsBeforeAttempt: []
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        await service.reconcile()
        await service.completeOnchainPayment(
            request,
            txid: String(repeating: "cd", count: 32),
            paymentEndpointIdentifier: endpoint
        )
        await service.failOnchainPayment(request)

        do {
            try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
            XCTFail("A foreign-wallet proof must keep duplicate-payment protection")
        } catch let error as PaykitPaymentRequestError {
            XCTAssertEqual(error, .operationInProgress)
        }

        let submissionCount = await sdk.submissionCount()
        let storedProofs = await store.snapshot()
        let inFlightRequestIds = await service.inFlightRequestIds(identity: identity)
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(storedProofs, [proof])
        XCTAssertEqual(inFlightRequestIds, [request.id])
    }

    func testForeignWalletOnchainProofClearsAfterMatchingRemoteSettlement() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let requestRecord = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: requestRecord, now: Date()))
        let transactionId = String(repeating: "ab", count: 32)
        let remoteProof = try paymentProofRecord(endpoint: endpoint, kind: .onchain, data: transactionId)
        let settledRecord = try paymentRequestRecord(
            endpoints: [endpoint],
            paymentProofs: [remoteProof],
            state: .proofSubmitted
        )
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: nil,
            proofData: nil,
            onchainAddress: onchainAddress,
            onchainAmountSats: request.amountSats,
            onchainWalletId: "trezor:android",
            onchainMatchingTransactionIdsBeforeAttempt: []
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [settledRecord])
        let service = paymentProofService(sdk: sdk, store: store)

        await service.reconcile()

        let storedProofs = await store.snapshot()
        let inFlightRequestIds = await service.inFlightRequestIds(identity: identity)
        let submissionCount = await sdk.submissionCount()
        XCTAssertTrue(storedProofs.isEmpty)
        XCTAssertTrue(inFlightRequestIds.isEmpty)
        XCTAssertEqual(submissionCount, 0)
    }

    func testForeignWalletCompletedProofRequiresMatchingRemoteTransaction() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let requestRecord = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: requestRecord, now: Date()))
        let localTransactionId = String(repeating: "ab", count: 32)
        let remoteProof = try paymentProofRecord(
            endpoint: endpoint,
            kind: .onchain,
            data: String(repeating: "cd", count: 32)
        )
        let settledRecord = try paymentRequestRecord(
            endpoints: [endpoint],
            paymentProofs: [remoteProof],
            state: .proofSubmitted
        )
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: localTransactionId,
            proofData: localTransactionId,
            onchainWalletId: "trezor:android"
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [settledRecord]),
            store: store
        )

        await service.reconcile()

        let storedProofs = await store.snapshot()
        XCTAssertEqual(storedProofs, [proof])
    }

    func testForeignWalletRecurringProofRequiresExactRemoteBillingPeriod() async throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00.123456789Z",
            anchor: "2027-01-01T08:00:00.123456789Z",
            endsAt: nil
        )
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let exactPeriod = BillingPeriod(
            startsAt: "2027-01-01T08:00:00.123456789Z",
            endsAt: "2027-02-01T08:00:00.123456789Z"
        )
        let remoteProof = try paymentProofRecord(
            endpoint: endpoint,
            kind: .onchain,
            data: String(repeating: "ab", count: 32),
            billingPeriod: exactPeriod
        )
        let record = try paymentRequestRecord(
            endpoints: [endpoint],
            paymentProofs: [remoteProof],
            state: .activeRecurring,
            recurrence: recurrence
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let request = try XCTUnwrap(subscription.requests(through: date, acceptedAt: PaykitPreciseInstant(date: date)).first)
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            billingPeriod: request.billingPeriod,
            paymentStarted: true,
            paymentIdentifier: nil,
            proofData: nil,
            onchainWalletId: "trezor:android"
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let service = paymentProofService(sdk: PaymentProofSdkMock(identity: identity, records: [record]), store: store)

        await service.reconcile()

        let storedProofs = await store.snapshot()
        XCTAssertTrue(storedProofs.isEmpty)
    }

    func testConcurrentForeignWalletReplacementSurvivesRemoteSettlementCleanup() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let requestRecord = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: requestRecord, now: Date()))
        let remoteProof = try paymentProofRecord(
            endpoint: endpoint,
            kind: .onchain,
            data: String(repeating: "ab", count: 32)
        )
        let settledRecord = try paymentRequestRecord(
            endpoints: [endpoint],
            paymentProofs: [remoteProof],
            state: .proofSubmitted
        )
        let originalProof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: nil,
            proofData: nil,
            onchainWalletId: "trezor:android"
        )
        let replacementProof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: nil,
            proofData: nil,
            onchainWalletId: "trezor:replacement"
        )
        let store = PaymentProofMemoryStore()
        await store.seed([originalProof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [settledRecord])
        await sdk.suspendPaymentRequestFetch()
        let service = paymentProofService(sdk: sdk, store: store)

        let reconciliation = Task { await service.reconcile() }
        await sdk.waitForPaymentRequestFetchStart()
        await store.seed([replacementProof])
        await sdk.resumePaymentRequestFetch()
        await reconciliation.value

        let storedProofs = await store.snapshot()
        XCTAssertEqual(storedProofs, [replacementProof])
    }

    func testForeignWalletCompletedProofIsRetainedWithoutSubmission() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: true,
            paymentIdentifier: txid,
            proofData: txid,
            onchainAddress: onchainAddress,
            onchainAmountSats: request.amountSats,
            onchainWalletId: "trezor:android",
            onchainMatchingTransactionIdsBeforeAttempt: []
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        await service.reconcile()

        let submissionCount = await sdk.submissionCount()
        let storedProofs = await store.snapshot()
        let completedProofKinds = await service.completedRequestProofKindsAwaitingSubmission(identity: identity)
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(storedProofs, [proof])
        XCTAssertTrue(completedProofKinds.isEmpty)
    }

    func testForeignWalletUnstartedProofSurvivesCancellationCleanup() async throws {
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
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            billingPeriod: request.billingPeriod,
            paymentStarted: false,
            paymentIdentifier: nil,
            proofData: nil,
            onchainWalletId: "trezor:android"
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let service = paymentProofService(
            sdk: PaymentProofSdkMock(identity: identity, records: [record]),
            store: store
        )

        await service.cancelPreparation(request)
        let protectedRequestIds = try await service.protectedRequestIdsForSubscriptionCancellation(
            identity: identity,
            subscriptionId: subscription.id
        )

        let storedProofs = await store.snapshot()
        XCTAssertTrue(protectedRequestIds.isEmpty)
        XCTAssertEqual(storedProofs, [proof])
    }

    func testLocalSubmissionCleanupRetainsForeignWalletProofForSameRequest() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let foreignProof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: request.id,
            paymentEndpointIdentifier: endpoint,
            kind: .onchain,
            paymentStarted: false,
            paymentIdentifier: nil,
            proofData: nil,
            onchainWalletId: "trezor:android"
        )
        let foreignProofRetained = expectation(description: "Foreign-wallet proof retained after local submission")
        let store = PaymentProofMemoryStore { proofs in
            if proofs == [foreignProof] {
                foreignProofRetained.fulfill()
            }
        }
        await store.seed([foreignProof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await service.completeOnchainPayment(
            request,
            txid: String(repeating: "ab", count: 32),
            paymentEndpointIdentifier: endpoint
        )
        await sdk.waitForSubmissionStart()
        await fulfillment(of: [foreignProofRetained], timeout: 1)

        let storedProofs = await store.snapshot()
        XCTAssertEqual(storedProofs, [foreignProof])
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
            lightningStatus: .succeeded(preimage: preimage)
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
        let request = try XCTUnwrap(
            subscription.requests(through: acceptedAt, acceptedAt: PaykitPreciseInstant(date: acceptedAt)).first
        )
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
        let request = try XCTUnwrap(subscription.requests(through: date, acceptedAt: PaykitPreciseInstant(date: date)).last)
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

    func testOnchainPaymentKeepsStartedProofWhenCompletionCannotBePersisted() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
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
        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(remainingProofs.first?.paymentStarted, true)
        XCTAssertNil(remainingProofs.first?.proofData)
    }

    func testFailedOnchainProofPersistenceKeepsStartedMarker() async throws {
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
        await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
        let storedProofs = await store.snapshot()
        let proof = try XCTUnwrap(storedProofs.first)
        XCTAssertNil(proof.proofData)
        let submissionCount = await sdk.submissionCount()
        XCTAssertEqual(submissionCount, 0)
    }

    func testOnchainPaymentKeepsStartedProofWhenPreparedProofCannotBeLoaded() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)

        try await service.prepare(request: request, paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await store.failNextLoad()
        await service.completeOnchainPayment(request, txid: txid, paymentEndpointIdentifier: endpoint)
        let submissionCount = await sdk.submissionCount()
        let remainingProofs = await store.snapshot()
        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(remainingProofs.first?.paymentStarted, true)
        XCTAssertNil(remainingProofs.first?.proofData)
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
        attemptService: OnchainSendAttemptService = OnchainSendAttemptService(store: MemoryAttemptStore())
    ) -> PaykitPaymentProofService {
        PaykitPaymentProofService(
            sdk: sdk,
            store: store,
            lightningPaymentLookup: PaymentProofLightningLookup(status: lightningStatus),
            attemptService: attemptService,
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
    private var shouldSuspendPaymentRequestFetch = false
    private var paymentRequestFetchStarted = false
    private var paymentRequestFetchContinuation: CheckedContinuation<Void, Never>?
    private var paymentRequestFetchStartContinuations: [CheckedContinuation<Void, Never>] = []

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

    func paymentRequests() async -> [PaymentRequestRecord] {
        paymentRequestFetchStarted = true
        paymentRequestFetchStartContinuations.forEach { $0.resume() }
        paymentRequestFetchStartContinuations.removeAll()
        if shouldSuspendPaymentRequestFetch {
            await withCheckedContinuation { continuation in
                paymentRequestFetchContinuation = continuation
            }
        }
        return records
    }

    func suspendPaymentRequestFetch() {
        shouldSuspendPaymentRequestFetch = true
    }

    func waitForPaymentRequestFetchStart() async {
        guard !paymentRequestFetchStarted else { return }
        await withCheckedContinuation { continuation in
            paymentRequestFetchStartContinuations.append(continuation)
        }
    }

    func resumePaymentRequestFetch() {
        shouldSuspendPaymentRequestFetch = false
        paymentRequestFetchContinuation?.resume()
        paymentRequestFetchContinuation = nil
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
