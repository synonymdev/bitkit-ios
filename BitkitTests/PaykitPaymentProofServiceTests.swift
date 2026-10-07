@testable import Bitkit
import BitkitCore
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

    private let hardwareWalletId = "trezor:original-ios-wallet"

    func testReplacementWinnerBindsOnlyOriginalUnverifiedStartedProof() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        for mismatch in 0 ..< 6 {
            let record = try paymentRequestRecord(endpoints: [endpoint])
            let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
            let attemptsStore = MemoryAttemptStore()
            let attempts = OnchainSendAttemptService(store: attemptsStore, localFollowup: FailingShopActivityFollowup())
            let sender = PreparedAttemptNodeMock()
            sender.amount = request.amountSats
            _ = try await attempts.send(using: sender, address: onchainAddress, amountSats: request.amountSats,
                                        satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false,
                                        requestId: request.id, paymentIdentity: identity)
            let original = try XCTUnwrap(attemptsStore.snapshot().first)
            let originalId = try XCTUnwrap(original.txid)
            sender.txid = String(repeating: "cd", count: 32)
            sender.result = .accepted(txid: sender.txid)
            _ = try await attempts.retrySamePayment(
                using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: originalId),
                authorize: { admitted, feeRate in
                    XCTAssertEqual(feeRate, 2)
                    XCTAssertEqual(admitted.requestId, request.id)
                    XCTAssertEqual(admitted.recoveryContext?.paymentIdentity, self.identity)
                    XCTAssertEqual(admitted.address, self.onchainAddress)
                    XCTAssertEqual(admitted.amountSats, request.amountSats)
                }
            )
            let proof = PendingPaykitPaymentProof(
                identity: mismatch == 1 ? "pubky" + String(repeating: "x", count: 52) : identity,
                requestId: request.id, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain,
                paymentStarted: true, paymentIdentifier: mismatch == 2 ? String(repeating: "ef", count: 32) : originalId,
                proofData: mismatch == 5 ? originalId : nil,
                onchainAddress: mismatch == 3 ? "different-address" : onchainAddress,
                onchainAmountSats: mismatch == 4 ? request.amountSats - 1 : request.amountSats,
                onchainAcceptanceVerified: mismatch == 5
            )
            let store = PaymentProofMemoryStore()
            await store.seed([proof])
            let sdk = PaymentProofSdkMock(identity: identity, records: [record])
            await sdk.setSubmissionFailure(true)
            let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
            let completed = await service.completeOnchainPayment(request, txid: sender.txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
            XCTAssertEqual(completed, mismatch == 0)
            let saved = await store.snapshot()
            if mismatch == 0 {
                XCTAssertEqual(saved.first?.paymentIdentifier, sender.txid)
                XCTAssertEqual(saved.first?.proofData, sender.txid)
                XCTAssertEqual(saved.first?.onchainAcceptanceVerified, true)
            } else {
                XCTAssertEqual(saved, [proof], "Foreign/verified proof was overwritten")
            }
            XCTAssertEqual(sender.broadcasts, 2)
        }
    }

    func testSoftwareStartedProofRequiresCapturedPayerWhenProvided() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let other = "pubky" + String(repeating: "x", count: 52)
        let proofs = [identity, other].map {
            PendingPaykitPaymentProof(identity: $0, requestId: request.id, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint,
                                      kind: .onchain, paymentIdentifier: nil, proofData: nil)
        }
        let store = PaymentProofMemoryStore()
        await store.seed(proofs)
        let sdk = PaymentProofSdkMock(identity: other, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        do {
            try await service.markOnchainPaymentStarted(request, address: onchainAddress, paymentIdentity: identity)
            XCTFail("Profile switch marked another payer's proof")
        } catch {}
        let saved = await store.snapshot()
        XCTAssertEqual(saved, proofs)
    }

    func testRecoveryAuthorizationUsesOriginalStartedRequestWithoutProofMutationOrSubmission() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        for invalid in 0 ..< 8 {
            let record = try paymentRequestRecord(endpoints: [endpoint], state: .accepted)
            let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
            let attemptsStore = MemoryAttemptStore()
            let attempts = OnchainSendAttemptService(store: attemptsStore)
            let sender = PreparedAttemptNodeMock()
            sender.amount = request.amountSats
            _ = try await attempts.send(using: sender, address: onchainAddress, amountSats: request.amountSats,
                                        satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false,
                                        requestId: request.id, paymentIdentity: identity)
            let original = try XCTUnwrap(attemptsStore.snapshot().first)
            let proof = PendingPaykitPaymentProof(
                identity: identity, requestId: request.id, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain,
                paymentStarted: invalid < 4, paymentIdentifier: original.txid, proofData: nil,
                onchainAddress: invalid % 4 == 2 ? "foreign-address" : onchainAddress,
                onchainAmountSats: request.amountSats
            )
            let store = PaymentProofMemoryStore()
            await store.seed([proof])
            let sdk = PaymentProofSdkMock(identity: invalid % 4 == 1 ? counterparty : identity, records: invalid % 4 == 3 ? [] : [record])
            let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
            do {
                let authorized = try await service.authorizeOnchainRecovery(original, restoreStartedProof: false)
                XCTAssertEqual(invalid % 4, 0)
                XCTAssertEqual(authorized.id, request.id)
                XCTAssertEqual(authorized.amountSats, request.amountSats)
            } catch { XCTAssertNotEqual(invalid % 4, 0) }
            let saved = await store.snapshot()
            let submissions = await sdk.submissionCount()
            XCTAssertEqual(saved, [proof])
            XCTAssertEqual(submissions, 0)
            XCTAssertEqual(sender.broadcasts, 1)
        }
    }

    func testHardwarePredispatchReleaseMatchesOnlyOriginalProofAndFailsClosedOnSave() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let otherIdentity = "pubky" + String(repeating: "x", count: 52)
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: otherIdentity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        func proof(payer: String, wallet: String, txid: String? = nil, verified: Bool = false,
                   requestId: PaykitPaymentRequest.ID? = nil) -> PendingPaykitPaymentProof
        {
            PendingPaykitPaymentProof(identity: payer, requestId: requestId ?? request.id, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint,
                                      kind: .onchain, paymentStarted: true, paymentIdentifier: txid, proofData: verified ? txid : nil,
                                      onchainWalletId: wallet, onchainAcceptanceVerified: verified)
        }
        let otherRequest = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(
            endpoints: [endpoint], paymentRequestId: UUID().uuidString
        ), now: Date()))
        let original = proof(payer: identity, wallet: hardwareWalletId)
        let retained = [proof(payer: otherIdentity, wallet: hardwareWalletId),
                        proof(payer: identity, wallet: "trezor:other-wallet"),
                        proof(payer: identity, wallet: hardwareWalletId, requestId: otherRequest.id),
                        proof(payer: identity, wallet: hardwareWalletId, verified: true),
                        proof(payer: identity, wallet: hardwareWalletId, txid: String(repeating: "ab", count: 32)),
                        proof(payer: identity, wallet: hardwareWalletId, txid: String(repeating: "cd", count: 32), verified: true)]
        await store.seed([original] + retained)
        await service.cancelHardwarePaymentBeforeDispatch(request, paymentIdentity: identity, walletId: "missing-wallet")
        let unchanged = await store.snapshot()
        XCTAssertEqual(unchanged, [original] + retained)
        await store.failNextSave()
        await service.cancelHardwarePaymentBeforeDispatch(request, paymentIdentity: identity, walletId: hardwareWalletId)
        let failedClear = await store.snapshot()
        XCTAssertEqual(failedClear, [original] + retained, "Failed durable clear must preserve every original guard")
        await service.cancelHardwarePaymentBeforeDispatch(request, paymentIdentity: identity, walletId: hardwareWalletId)
        let afterClear = await store.snapshot()
        XCTAssertEqual(
            afterClear,
            retained,
            "Current profile must not replace the captured payer; candidate/verified/other wallet proofs stay guarded"
        )
    }

    func testHardwareCompletionRetainsCapturedPayerAfterProfileSwitch() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint], paymentRequestId: UUID().uuidString)
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        let otherIdentity = "pubky" + String(repeating: "x", count: 52)
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        await sdk.setSubmissionFailure(true)
        let lookup = PaymentProofHardwareLookup(result: .success(hardwareTransaction(txid: txid)))
        let service = paymentProofService(sdk: sdk, store: store, hardwareLookup: lookup)
        func pending(_ payer: String) -> PendingPaykitPaymentProof {
            PendingPaykitPaymentProof(
                identity: payer, requestId: request.id, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain,
                paymentStarted: true, paymentIdentifier: nil, proofData: nil, onchainAddress: onchainAddress,
                onchainAmountSats: 1000, onchainWalletId: hardwareWalletId
            )
        }
        await store.seed([pending(identity), pending(otherIdentity)])
        await sdk.setIdentity(otherIdentity)
        var resolutions: [PaykitOnchainPaymentResolution] = []
        let subscription = PaykitPaymentProofService.onchainPaymentResolutionPublisher.sink { resolution in
            if resolution.requestId == request.id {
                resolutions.append(resolution)
            }
        }
        defer { subscription.cancel() }

        _ = await service.completeHardwareOnchainPayment(request, paymentIdentity: identity, walletId: hardwareWalletId, txid: txid)

        let proofs = await store.snapshot()
        let original = proofs.first { PubkyPublicKeyFormat.matches($0.identity, identity) }
        let other = proofs.first { PubkyPublicKeyFormat.matches($0.identity, otherIdentity) }
        XCTAssertEqual(original?.paymentIdentifier, txid)
        XCTAssertEqual(original?.proofData, txid)
        XCTAssertEqual(original?.onchainAcceptanceVerified, true)
        XCTAssertNil(other?.paymentIdentifier)
        XCTAssertNil(other?.proofData)
        XCTAssertEqual(other?.onchainAcceptanceVerified, false)
        let originalResolution = PaykitOnchainPaymentResolution(
            identity: identity, requestId: request.id, transactionId: txid, walletId: hardwareWalletId
        )
        XCTAssertEqual(resolutions, [originalResolution])
        await service.consumeOnchainPaymentResolution(originalResolution)
        await sdk.setIdentity(identity)
        await service.reconcile()
        XCTAssertEqual(
            resolutions,
            [originalResolution, originalResolution],
            "Returning to the original payer must resume its already verified local result"
        )
        let lookups = await lookup.calls()
        XCTAssertEqual(lookups.count, 1, "Already verified original follow-up must not repeat payment or observation")
    }

    func testHardwareShopProofRequiresExactFreshOriginalWalletObservation() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        await sdk.setSubmissionFailure(true)
        let lookup = PaymentProofHardwareLookup(result: .success(hardwareTransaction(txid: txid)))
        let service = paymentProofService(sdk: sdk, store: store, hardwareLookup: lookup)
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress, hardwareWalletId: hardwareWalletId, paymentIdentity: identity)

        let completed = await service.completeHardwareOnchainPayment(request, paymentIdentity: identity, walletId: hardwareWalletId, txid: txid)

        XCTAssertTrue(completed)
        let proof = await store.snapshot().first
        XCTAssertEqual(proof?.paymentIdentifier, txid)
        XCTAssertEqual(proof?.proofData, txid)
        XCTAssertEqual(proof?.onchainAcceptanceVerified, true)
        XCTAssertEqual(proof?.onchainWalletId, hardwareWalletId)
        let observed = await lookup.calls()
        XCTAssertEqual(observed, [.init(walletId: hardwareWalletId, txid: txid)])
        let nativeAttempt = try await serviceAttempts[ObjectIdentifier(service)]?.unresolvedAttempt(walletId: WalletScope.default)
        XCTAssertNil(nativeAttempt)
        if completed {
            await sdk.waitForSubmissionStart()
        }
        let submissionCount = await sdk.submissionCount()
        XCTAssertEqual(submissionCount, 1)

        await sdk.setSubmissionFailure(false)
        let restarted = paymentProofService(sdk: sdk, store: store, hardwareLookup: lookup)
        await restarted.reconcile()
        let remainingProofs = await store.snapshot()
        XCTAssertTrue(remainingProofs.isEmpty)
        let submitted = await sdk.lastSubmission()
        XCTAssertEqual(try submitted.map { try proofValues($0.proof.exportText()) }, ["type": PaykitPaymentProofKind.onchain.rawValue, "data": txid])
        let observationsAfterDelivery = await lookup.calls()
        XCTAssertEqual(observationsAfterDelivery.count, 1, "Verified proof delivery needs no second lookup or payment")
    }

    func testHardwareMissingMismatchedOrInboundObservationStaysPendingAndRestartUsesOriginalContext() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        let failures: [Result<TransactionDetail, Error>] = [
            .failure(AccountInfoError.TransactionNotFound(errorDetails: "not observed")),
            .failure(PaymentProofStoreMockError.load),
            .success(hardwareTransaction(txid: String(repeating: "cd", count: 32))),
            .success(hardwareTransaction(txid: txid, sent: 0)),
        ]
        for result in failures {
            let store = PaymentProofMemoryStore()
            let sdk = PaymentProofSdkMock(identity: identity, records: [record])
            await sdk.setSubmissionFailure(true)
            let lookup = PaymentProofHardwareLookup(result: result)
            let service = paymentProofService(sdk: sdk, store: store, hardwareLookup: lookup)
            try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
            try await service.markOnchainPaymentStarted(
                request,
                address: onchainAddress,
                hardwareWalletId: hardwareWalletId,
                paymentIdentity: identity
            )

            let completed = await service.completeHardwareOnchainPayment(request, paymentIdentity: identity, walletId: hardwareWalletId, txid: txid)
            XCTAssertFalse(completed)
            let pending = await store.snapshot()
            XCTAssertEqual(pending.first?.paymentIdentifier, txid)
            XCTAssertNil(pending.first?.proofData)
            XCTAssertEqual(pending.first?.onchainAcceptanceVerified, false)
            XCTAssertEqual(pending.first?.paymentStarted, true)
            let submissions = await sdk.submissionCount()
            XCTAssertEqual(submissions, 0)
            do {
                try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
                XCTFail("Original hardware payment must prevent a second payment")
            } catch { XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress) }

            let backup = try JSONDecoder().decode(
                [PaykitPaymentStateBackup.Proof].self,
                from: JSONEncoder().encode(pending.map(PaykitPaymentStateBackup.Proof.init))
            )
            let restartedLookup = PaymentProofHardwareLookup(result: .success(hardwareTransaction(txid: txid)))
            let restarted = paymentProofService(sdk: sdk, store: store, hardwareLookup: restartedLookup)
            try await restarted.restoreBackup(backup)
            await restarted.reconcile()
            let recovered = await store.snapshot().first
            XCTAssertEqual(recovered?.proofData, txid)
            XCTAssertEqual(recovered?.onchainAcceptanceVerified, true)
            let observed = await restartedLookup.calls()
            XCTAssertEqual(observed, [.init(walletId: hardwareWalletId, txid: txid)])
            let nativeAttempt = try await serviceAttempts[ObjectIdentifier(restarted)]?.unresolvedAttempt(walletId: WalletScope.default)
            XCTAssertNil(nativeAttempt)
        }
    }

    func testExactHardwareCandidateReleaseRequiresDurableClear() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let signed = "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300"
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress, hardwareWalletId: hardwareWalletId, paymentIdentity: identity)
        try await service.retainHardwareOnchainCandidate(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId,
            address: onchainAddress, amountSats: request.amountSats, serializedTx: signed
        )
        await store.failNextSave()
        let failed = await service.clearHardwareCandidateBeforeDispatch(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId, serializedTx: signed
        )
        XCTAssertFalse(failed)
        let retained = await store.snapshot()
        XCTAssertEqual(retained.count, 1)
        let foreign = await service.clearHardwareCandidateBeforeDispatch(
            requestId: request.id, paymentIdentity: identity, walletId: "trezor:other-wallet", serializedTx: signed
        )
        XCTAssertFalse(foreign)
        let cleared = await service.clearHardwareCandidateBeforeDispatch(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId, serializedTx: signed
        )
        XCTAssertTrue(cleared)
        let remaining = await store.snapshot()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testHardwareStartAtomicallyRetainsReceiptAcrossAuthorizationBackup() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let serializedTx = "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300"
        let receipt = HwFundingSignedTx(serializedTx: serializedTx, miningFeeSats: 141, feeRate: 2, totalSpent: request.amountSats + 141)
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        await store.failNextSave()
        do {
            try await service.markOnchainPaymentStarted(
                request, address: onchainAddress, hardwareWalletId: hardwareWalletId,
                paymentIdentity: identity, signedTx: receipt
            )
            XCTFail("Failed atomic receipt save must stop preparation")
        } catch {}
        let unsaved = await store.snapshot().first
        XCTAssertEqual(unsaved?.paymentStarted, false)
        XCTAssertNil(unsaved?.hardwareSignedTransaction)
        try await service.markOnchainPaymentStarted(
            request, address: onchainAddress, hardwareWalletId: hardwareWalletId,
            paymentIdentity: identity, signedTx: receipt
        )
        let started = await store.snapshot().first
        XCTAssertEqual(started?.hardwareSignedTransaction, serializedTx)
        XCTAssertEqual(started?.paymentIdentifier, try SignedTransactionId.fromHex(serializedTx))
        XCTAssertEqual(started?.paymentStarted, true)
        XCTAssertNil(started?.proofData)
        let snapshot = try await service.backupSnapshot()
        let encoded = try JSONEncoder().encode(snapshot)
        await store.clear()
        let reopened = paymentProofService(sdk: sdk, store: store)
        try await reopened.restoreBackup(JSONDecoder().decode([PaykitPaymentStateBackup.Proof].self, from: encoded))
        let restored = await store.snapshot().first
        XCTAssertEqual(restored?.hardwareSignedTransaction, serializedTx)
        XCTAssertEqual(restored?.paymentIdentifier, started?.paymentIdentifier)
        let retained = try await reopened.retainedHardwareOnchainPayment(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId,
            address: onchainAddress, amountSats: request.amountSats
        )
        XCTAssertEqual(retained?.signedTx, receipt)
        XCTAssertEqual(retained?.hasAttemptedBroadcast, false)
        let wrongAmount = try await reopened.retainedHardwareOnchainPayment(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId,
            address: onchainAddress, amountSats: request.amountSats + 1
        )
        XCTAssertNil(wrongAmount)
        await reopened.cancelHardwarePaymentBeforeDispatch(request, paymentIdentity: identity, walletId: hardwareWalletId)
        let cleared = await store.snapshot()
        XCTAssertTrue(cleared.isEmpty, "Known pre-dispatch receipt must be removed")
        try await reopened.restoreBackup(JSONDecoder().decode([PaykitPaymentStateBackup.Proof].self, from: encoded))
        try await reopened.retainHardwareOnchainCandidate(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId,
            address: onchainAddress, amountSats: request.amountSats, serializedTx: serializedTx
        )
        let attemptedBackup = try await reopened.backupSnapshot()
        let attemptedEncoded = try JSONEncoder().encode(attemptedBackup)
        await store.clear()
        try await reopened.restoreBackup(JSONDecoder().decode([PaykitPaymentStateBackup.Proof].self, from: attemptedEncoded))
        let attempted = try await reopened.retainedHardwareOnchainPayment(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId,
            address: onchainAddress, amountSats: request.amountSats
        )
        XCTAssertEqual(attempted?.hasAttemptedBroadcast, true)
        await reopened.cancelHardwarePaymentBeforeDispatch(request, paymentIdentity: identity, walletId: hardwareWalletId)
        let guarded = await store.snapshot()
        XCTAssertEqual(guarded.count, 1)
    }

    func testHardwareTransactionIdMatchesBackendAndRejectsInvalidReceipt() throws {
        let signed = "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300"
        let legacy = "0200000001f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa724c0300"
        let expected = "605fe246a6d51450ecff51ac3d0415f8824964e06a60ed6e186fa163cf1e9d4e"
        XCTAssertEqual(try SignedTransactionId.fromHex(signed), expected)
        XCTAssertEqual(try SignedTransactionId.fromHex(legacy), expected)
        XCTAssertThrowsError(try SignedTransactionId.fromHex(String(signed.dropLast(2))))
        XCTAssertThrowsError(try SignedTransactionId.fromHex(signed + "00"))
        XCTAssertThrowsError(try SignedTransactionId.fromHex("not-a-transaction"))
    }

    func testHardwareRestartWithoutBroadcastReturnObservesOriginalCandidate() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = "605fe246a6d51450ecff51ac3d0415f8824964e06a60ed6e186fa163cf1e9d4e"
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        await sdk.setSubmissionFailure(true)
        let lookup = PaymentProofHardwareLookup(result: .success(hardwareTransaction(txid: txid)))
        let service = paymentProofService(sdk: sdk, store: store, hardwareLookup: lookup)
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress, hardwareWalletId: hardwareWalletId, paymentIdentity: identity)
        let serializedTx = "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300"
        await store.failNextSave()
        do {
            try await service.retainHardwareOnchainCandidate(
                requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId,
                address: onchainAddress, amountSats: request.amountSats, serializedTx: serializedTx
            )
            XCTFail("Failed receipt persistence must stop dispatch")
        } catch {}
        let unsaved = await store.snapshot().first
        XCTAssertNil(unsaved?.paymentIdentifier)
        try await service.retainHardwareOnchainCandidate(
            requestId: request.id, paymentIdentity: identity, walletId: hardwareWalletId,
            address: onchainAddress, amountSats: request.amountSats, serializedTx: serializedTx
        )
        let retained = await store.snapshot().first
        XCTAssertEqual(retained?.paymentIdentifier, txid)
        XCTAssertNil(retained?.proofData)
        XCTAssertEqual(retained?.onchainAcceptanceVerified, false)
        do {
            try await service.retainHardwareOnchainCandidate(
                requestId: request.id, paymentIdentity: identity, walletId: "trezor:other-wallet",
                address: onchainAddress, amountSats: request.amountSats, serializedTx: serializedTx
            )
            XCTFail("Another wallet cannot replace the original hardware receipt")
        } catch {}
        // The native dispatch has no return value: recreate the service from its durable backup.
        let snapshot = try await service.backupSnapshot()
        let backup = try JSONDecoder().decode([PaykitPaymentStateBackup.Proof].self, from: JSONEncoder().encode(snapshot))
        await store.clear()
        let restarted = paymentProofService(sdk: sdk, store: store, hardwareLookup: lookup)
        try await restarted.restoreBackup(backup)
        await restarted.reconcile()
        let observed = await lookup.calls()
        XCTAssertEqual(observed, [.init(walletId: hardwareWalletId, txid: txid)])
        let restored = await store.snapshot().first
        XCTAssertEqual(restored?.hardwareSignedTransaction, serializedTx)
        XCTAssertEqual(restored?.paymentIdentifier, txid)
        XCTAssertEqual(restored?.onchainAcceptanceVerified, true)
    }

    func testHardwareCandidateCannotBeReplacedByDifferentWalletRequestOrTxid() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let otherRecord = try paymentRequestRecord(endpoints: [endpoint], paymentRequestId: UUID().uuidString)
        let otherRequest = try XCTUnwrap(PaykitPaymentRequest(record: otherRecord, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record, otherRecord])
        let lookup = PaymentProofHardwareLookup(result: .failure(PaymentProofStoreMockError.load))
        let service = paymentProofService(sdk: sdk, store: store, hardwareLookup: lookup)
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress, hardwareWalletId: hardwareWalletId, paymentIdentity: identity)
        _ = await service.completeHardwareOnchainPayment(request, paymentIdentity: identity, walletId: hardwareWalletId, txid: txid)

        let wrongWallet = await service.completeHardwareOnchainPayment(request, paymentIdentity: identity, walletId: "trezor:new-wallet", txid: txid)
        let wrongRequest = await service.completeHardwareOnchainPayment(
            otherRequest,
            paymentIdentity: identity,
            walletId: hardwareWalletId,
            txid: txid
        )
        let wrongTxid = await service.completeHardwareOnchainPayment(request, paymentIdentity: identity, walletId: hardwareWalletId,
                                                                     txid: String(repeating: "cd", count: 32))
        XCTAssertFalse(wrongWallet)
        XCTAssertFalse(wrongRequest)
        XCTAssertFalse(wrongTxid)
        let proof = await store.snapshot().first
        XCTAssertEqual(proof?.paymentIdentifier, txid)
        XCTAssertEqual(proof?.onchainWalletId, hardwareWalletId)
        let observed = await lookup.calls()
        XCTAssertEqual(observed.count, 1)
    }

    func testLightningCompletionCannotOverwriteConcurrentOnchainStart() async throws {
        let onchainEndpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [onchainEndpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let started = PendingPaykitPaymentProof(
            identity: identity, requestId: request.id, paymentAppId: "bitkit", paymentEndpointIdentifier: onchainEndpoint,
            kind: .onchain, paymentIdentifier: nil, proofData: nil
        )
        let lightningId = PaykitPaymentRequest.ID(
            paymentRequestId: UUID().uuidString, counterparty: counterparty, billingPeriodStartsAt: nil
        )
        let lightning = PendingPaykitPaymentProof(
            identity: identity, requestId: lightningId,
            paymentAppId: "bitkit", paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning, paymentStarted: true, paymentIdentifier: paymentHash, proofData: nil
        )
        let store = SuspendedProofSaveStore(proofs: [started, lightning])
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        await sdk.setSubmissionFailure(true)
        let service = PaykitPaymentProofService(
            sdk: sdk, store: store, attemptService: OnchainSendAttemptService(store: MemoryAttemptStore()),
            logInfo: { _ in }, logWarning: { _ in }
        )
        let completion = Task { await service.completeLightningPayment(paymentHash: paymentHash, preimage: preimage) }
        await store.waitForSuspendedSave()
        let marking = Task { try await service.markOnchainPaymentStarted(request, address: onchainAddress) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await store.resumeSave()
        await completion.value
        try await marking.value
        let proofs = try await store.load()
        XCTAssertEqual(proofs.first(where: { $0.requestId == request.id })?.paymentStarted, true)
        XCTAssertEqual(proofs.first(where: { $0.requestId == lightningId })?.proofData, preimage)
    }

    private func hardwareTransaction(txid: String, sent: UInt64 = 1200) -> TransactionDetail {
        TransactionDetail(
            txid: txid, received: 100, sent: sent, net: -1100, amount: 1000, fee: 100,
            direction: sent > 0 ? .sent : .received, blockHeight: nil, timestamp: nil, confirmations: 0,
            inputs: [], outputs: [], size: 112, vsize: 112, weight: 448, feeRate: 1
        )
    }

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

    func testCompletedLightningPaymentRetriesAfterRestartPastPaymentDeadline() async throws {
        var record = try paymentRequestRecord()
        let deadline = Date().addingTimeInterval(-60)
        record.terms?.paymentDeadline = .at(timestamp: ISO8601DateFormatter().string(from: deadline))
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: deadline.addingTimeInterval(-1)))
        XCTAssertTrue(request.isPaymentDeadlineExpired(at: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        await sdk.setSubmissionFailure(true)

        let service = paymentProofService(sdk: sdk, store: store)
        try await service.prepare(
            request: request,
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit", paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
                paymentAppId: "bitkit",
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
            PaykitPaymentRequestError.requestExpired,
            Bitkit.AppError(error: PaykitPaymentRequestError.requestExpired),
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
                paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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

        try await service.prepare(request: request, paymentAppId: "paykit-server", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        let inFlightRequestIds = await service.inFlightRequestIds(identity: identity)
        XCTAssertEqual(inFlightRequestIds, [request.id])
        try await recordAcceptedAttempt(service: service, request: request, txid: String(repeating: "ab", count: 32))
        await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
        await sdk.waitForSubmissionStart()
        await fulfillment(of: [proofRemoved], timeout: 1)

        let submittedProof = await sdk.lastSubmission()
        let submission = try XCTUnwrap(submittedProof)
        XCTAssertEqual(submission.paymentAppId, "paykit-server")
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        try await recordAcceptedAttempt(service: service, request: request, txid: String(repeating: "ab", count: 32))
        await sdk.suspendSubmission()
        let completionTask = Task {
            await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 1)
        await sdk.waitForSubmissionStart()

        let persistedProof = await store.snapshot().first
        XCTAssertEqual(persistedProof?.paymentIdentifier, txid)
        XCTAssertEqual(persistedProof?.proofData, txid)
        XCTAssertEqual(persistedProof?.onchainAcceptanceVerified, true)

        await sdk.resumeSubmission()
        await completionTask.value
    }

    func testAcceptedOnchainCompletionWaitsForOriginalIdentityBeforeProofDelivery() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let service = paymentProofService(sdk: sdk, store: store)
        let txid = String(repeating: "ab", count: 32)
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        try await recordAcceptedAttempt(service: service, request: request, txid: txid)
        await sdk.setIdentityAvailable(false)

        let completed = await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
        XCTAssertFalse(completed)
        let waitingProof = await store.snapshot().first
        XCTAssertEqual(waitingProof?.paymentStarted, true)
        XCTAssertNil(waitingProof?.proofData)
        let attempts = try XCTUnwrap(serviceAttempts[ObjectIdentifier(service)])
        let acceptedTxid = try await attempts.acceptedTransactionId(for: request.id)
        XCTAssertEqual(acceptedTxid, txid)
        await sdk.suspendSubmission()
        await sdk.setIdentityAvailable(true)
        await service.reconcile()

        let proof = await store.snapshot().first
        XCTAssertEqual(proof?.paymentIdentifier, txid)
        XCTAssertEqual(proof?.proofData, txid)
        await sdk.resumeSubmission()
    }

    func testStartedOnchainPaymentSurvivesPreparationCancellation() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let service = paymentProofService(sdk: PaymentProofSdkMock(identity: identity, records: [record]), store: store)

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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

    func testSavedAcceptedShopProofSubmitsAfterCurrentGuardIsReplaced() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let store = PaymentProofMemoryStore()
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let attemptStore = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: attemptStore)
        let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
        let txid = String(repeating: "ab", count: 32)
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        let id = try await attempts.admit(
            walletId: "node-0", requestId: request.id, orderId: nil,
            address: onchainAddress, amountSats: request.amountSats, isMaxAmount: false
        )
        try await attempts.record(.accepted(txid: txid), attemptId: id)
        await sdk.setSubmissionFailure(true)
        let completed = await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
        XCTAssertTrue(completed)
        await sdk.waitForSubmissionStart()
        await sdk.setIdentityAvailable(false)
        try await attempts.acknowledgeLocalFollowup(txid: txid)
        _ = try await attempts.admit(
            walletId: "node-0", requestId: nil, orderId: nil,
            address: "bcrt1qnew", amountSats: 9000, isMaxAmount: false
        )
        let countBefore = await sdk.submissionCount()
        await sdk.setIdentityAvailable(true)
        await sdk.setSubmissionFailure(false)
        let restarted = paymentProofService(
            sdk: sdk, store: store, attemptService: OnchainSendAttemptService(store: attemptStore)
        )
        await restarted.reconcile()
        let countAfter = await sdk.submissionCount()
        let submitted = await sdk.lastSubmission()
        XCTAssertGreaterThan(countAfter, countBefore)
        XCTAssertEqual(try proofValues(XCTUnwrap(submitted).proof.exportText()), ["data": txid, "type": PaykitPaymentProofKind.onchain.rawValue])
        XCTAssertEqual(attemptStore.snapshot().first?.status, .pending, "Earlier paid proof mutated the later send guard")
    }

    func testOnchainProofWriterRequiresExactPositiveAttemptEvidence() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        for result in [OnchainSendResult.unknown(txid: txid), .rejected(txid: txid, reason: "fixture refusal"),
                       .accepted(txid: String(repeating: "cd", count: 32))]
        {
            let store = PaymentProofMemoryStore()
            let attempts = OnchainSendAttemptService(store: MemoryAttemptStore())
            let sdk = PaymentProofSdkMock(identity: identity, records: [record])
            let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
            try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
            try await service.markOnchainPaymentStarted(request, address: onchainAddress)
            let id = try await attempts.admit(
                walletId: "node-0", requestId: request.id, orderId: nil,
                address: onchainAddress, amountSats: request.amountSats, isMaxAmount: false
            )
            try await attempts.record(result, attemptId: id)
            let completed = await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
            XCTAssertFalse(completed, "A bare txid became acceptance evidence")
            let proof = await store.snapshot().first
            XCTAssertNotEqual(proof?.onchainAcceptanceVerified, true)
            XCTAssertNil(proof?.proofData)
            let count = await sdk.submissionCount()
            XCTAssertEqual(count, 0)
        }
    }

    func testUnmarkedOnchainProofUpgradesOnlyFromExactCurrentPositiveAttempt() async throws {
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let txid = String(repeating: "ab", count: 32)
        for observed in [false, true] {
            let store = PaymentProofMemoryStore()
            await store.seed([PendingPaykitPaymentProof(
                identity: identity, requestId: request.id, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint,
                kind: .onchain, paymentStarted: true, paymentIdentifier: txid, proofData: txid,
                onchainAcceptanceVerified: nil
            )])
            let attempts = OnchainSendAttemptService(store: MemoryAttemptStore())
            let id = try await attempts.admit(
                walletId: "node-0", requestId: request.id, orderId: nil,
                address: onchainAddress, amountSats: request.amountSats, isMaxAmount: false
            )
            try await attempts.record(observed ? .unknown(txid: txid) : .accepted(txid: txid), attemptId: id)
            let sdk = PaymentProofSdkMock(identity: identity, records: [record])
            await sdk.setSubmissionFailure(true)
            let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
            if observed {
                await service.reconcile()
                let unmarked = await store.snapshot().first
                XCTAssertNotEqual(unmarked?.onchainAcceptanceVerified, true)
                let count = await sdk.submissionCount()
                XCTAssertEqual(count, 0)
                _ = try await attempts.observeConfirmedTransaction(txid: txid.uppercased())
            }
            await service.reconcile()
            let upgraded = await store.snapshot().first
            XCTAssertEqual(upgraded?.onchainAcceptanceVerified, true)
            XCTAssertEqual(upgraded?.paymentIdentifier, txid)
            let kinds = await service.completedRequestProofKindsAwaitingSubmission(identity: identity)
            XCTAssertEqual(kinds[request.id], .onchain)
        }
    }

    func testAcceptedShopProofFailureRestartsOriginalActivityAndDurableAck() async throws {
        let dbPath = FileManager.default.temporaryDirectory.appendingPathComponent("ShopAcceptedResume-\(UUID())")
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true)
        _ = try initDb(basePath: dbPath.path)
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let record = try paymentRequestRecord(endpoints: [endpoint])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let proofDelivered = expectation(description: "Original positive proof moved to durable SDK request store")
        let store = PaymentProofMemoryStore { proofs in
            if proofs.isEmpty {
                proofDelivered.fulfill()
            }
        }
        let sdk = PaymentProofSdkMock(identity: identity, records: [record])
        let attemptStore = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: attemptStore)
        let service = paymentProofService(sdk: sdk, store: store, attemptService: attempts)
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        _ = try await attempts.send(
            using: node, address: onchainAddress, amountSats: request.amountSats,
            satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false, requestId: request.id,
            followupContext: OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: ["original"], contact: nil, createdAt: 100)
        ) { try await service.markOnchainPaymentStarted(request, address: self.onchainAddress) }
        await store.failNextSave()
        let completed = await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
        XCTAssertFalse(completed)
        XCTAssertEqual(attemptStore.snapshot().first?.localFollowupComplete, false)
        let failedActivityRestart = paymentProofService(
            sdk: sdk, store: store,
            attemptService: OnchainSendAttemptService(store: attemptStore, localFollowup: FailingShopActivityFollowup())
        )
        await failedActivityRestart.reconcile()
        await fulfillment(of: [proofDelivered], timeout: 2)
        let deliveredProofs = await store.snapshot()
        XCTAssertTrue(deliveredProofs.isEmpty)
        XCTAssertEqual(attemptStore.snapshot().first?.localFollowupComplete, false)
        let restarted = paymentProofService(
            sdk: sdk, store: store, attemptService: OnchainSendAttemptService(store: attemptStore)
        )
        await restarted.reconcile()
        XCTAssertEqual(attemptStore.snapshot().first?.localFollowupComplete, true)
        let saved = try await Bitkit.CoreService.shared.activity.getOnchainActivityByTxId(txid: txid)
        XCTAssertEqual(saved?.value, request.amountSats)
        XCTAssertEqual(saved?.address, onchainAddress)
        XCTAssertEqual(saved?.fee, 123)
        XCTAssertEqual(node.calls, 1)
        await repointCoreToAppStorage()
        try? FileManager.default.removeItem(at: dbPath)
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
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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
        XCTAssertEqual(attemptStore.snapshot().first?.txid, txid, "Pre-dispatch receipt remains durable even when the acceptance update fails")
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
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        _ = try await attempts.send(
            using: node, address: onchainAddress, amountSats: request.amountSats,
            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: true, requestId: request.id
        ) { try await service.markOnchainPaymentStarted(request, address: self.onchainAddress) }
        await store.failNextSave()
        let saved = await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
        XCTAssertFalse(saved)
        XCTAssertEqual(attemptStore.snapshot().first?.status, .accepted)
        XCTAssertEqual(attemptStore.snapshot().first?.localFollowupComplete, false)
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        let resumed = try await attempts.send(
            using: node, address: onchainAddress, amountSats: request.amountSats,
            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: true, requestId: request.id
        )
        XCTAssertEqual(resumed, .accepted(txid: txid))
        let retrySaved = await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
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
                paymentAppId: "bitkit", paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
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
            try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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
            paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint,
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: onchainEndpoint, kind: .onchain)
        _ = try await attempts.admit(
            walletId: "node-0", requestId: request.id, orderId: nil,
            address: onchainAddress, amountSats: request.amountSats, isMaxAmount: false
        )
        do {
            try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: lightningEndpoint, kind: .lightning)
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
                paymentAppId: "bitkit", paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
            paymentEndpointIdentifier: endpoint
        )
        await service.failOnchainPayment(request)

        do {
            try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        try await recordAcceptedAttempt(service: service, request: request, txid: String(repeating: "ab", count: 32))
        await service.completeOnchainPayment(
            request,
            txid: String(repeating: "ab", count: 32),
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
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
        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .lightning)
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        try await service.associateLightningPayment(request, paymentHash: paymentHash)
        do {
            try await service.prepare(
                request: request,
                paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
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
            paymentAppId: "bitkit",
            paymentEndpointIdentifier: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning
        )
        await store.clear()
        try await service.prepare(
            request: secondRequest,
            paymentAppId: "bitkit",
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await store.failNextSave()
        try await recordAcceptedAttempt(service: service, request: request, txid: String(repeating: "ab", count: 32))
        await service.completeOnchainPayment(
            request,
            txid: String(repeating: "ab", count: 32),
            paymentAppId: "bitkit",
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await store.failNextSave()
        try await recordAcceptedAttempt(service: service, request: request, txid: String(repeating: "ab", count: 32))
        await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
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

        try await service.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        try await service.markOnchainPaymentStarted(request, address: onchainAddress)
        await store.failNextLoad()
        try await recordAcceptedAttempt(service: service, request: request, txid: String(repeating: "ab", count: 32))
        await service.completeOnchainPayment(request, txid: txid, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint)
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

    private var serviceAttempts: [ObjectIdentifier: OnchainSendAttemptService] = [:]

    private func recordAcceptedAttempt(service: PaykitPaymentProofService, request: PaykitPaymentRequest, txid: String) async throws {
        let attempts = try XCTUnwrap(serviceAttempts[ObjectIdentifier(service)])
        let id = try await attempts.admit(
            walletId: "node-0", requestId: request.id, orderId: nil,
            address: onchainAddress, amountSats: request.amountSats, isMaxAmount: false
        )
        try await attempts.record(.accepted(txid: txid), attemptId: id)
    }

    private func paymentProofService(
        sdk: PaymentProofSdkMock,
        store: PaymentProofMemoryStore,
        lightningStatus: PaykitLightningPaymentProofStatus = .unknown,
        hardwareLookup: any PaykitHardwareTransactionLookingUp = PaymentProofHardwareLookup(result: .failure(PaymentProofStoreMockError.load)),
        attemptService: OnchainSendAttemptService = OnchainSendAttemptService(store: MemoryAttemptStore())
    ) -> PaykitPaymentProofService {
        let service = PaykitPaymentProofService(
            sdk: sdk,
            store: store,
            lightningPaymentLookup: PaymentProofLightningLookup(status: lightningStatus),
            hardwareTransactionLookup: hardwareLookup,
            hardwareFollowup: { _, _ in },
            attemptService: attemptService,
            logInfo: { _ in },
            logWarning: { _ in }
        )
        serviceAttempts[ObjectIdentifier(service)] = attemptService
        return service
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
            paymentRequestId: paymentRequestId,
            localRole: .payer,
            state: state,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            proposalAppId: "bitkit",
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.00001", asset: "btc"),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil,
                recurrence: recurrence,
                acceptedPaymentEndpointIdentifiers: endpoints,
                paymentEndpoints: nil,
                requiredAppId: "bitkit",
                conversion: nil,
                paymentDeadline: nil,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            conversionQuotes: [],
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
            paymentAppId: "bitkit",
            paymentEndpointIdentifier: endpoint,
            allowanceId: nil,
            conversionQuoteId: nil,
            proof: PrivateJsonObject(text: "{\"data\":\"\(data)\",\"type\":\"\(kind.rawValue)\"}"),
            recordedAt: "2027-01-15T08:01:00Z"
        )
    }

    private func proofValues(_ text: String) throws -> [String: String] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}

private struct FailingShopActivityFollowup: OnchainSendLocalFollowupHandling {
    func save(_: OnchainSendAttempt) async throws -> OnchainActivity {
        throw OnchainSendAttemptError.localFollowupNotSaved
    }
}

actor PaymentProofMemoryStore: PaykitPaymentProofStoring {
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

actor PaymentProofHardwareLookup: PaykitHardwareTransactionLookingUp {
    struct Call: Equatable {
        let walletId: String
        let txid: String
    }

    let result: Result<TransactionDetail, Error>
    private var observed: [Call] = []

    init(result: Result<TransactionDetail, Error>) {
        self.result = result
    }

    nonisolated func hasWallet(walletId: String) -> Bool {
        walletId == "trezor:original-ios-wallet"
    }

    func transactionDetail(walletId: String, txid: String) throws -> TransactionDetail {
        observed.append(Call(walletId: walletId, txid: txid))
        return try result.get()
    }

    func calls() -> [Call] {
        observed
    }
}

actor PaymentProofSdkMock: PaykitPaymentProofSdkHandling {
    private var identity: String
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
        return IdentityStatus(publicKey: identity, capability: .privateLinkCapable)
    }

    func setIdentity(_ identity: String) {
        self.identity = identity
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
            paymentAppId: proof.paymentAppId,
            paymentEndpointIdentifier: proof.paymentEndpointIdentifier,
            allowanceId: nil,
            conversionQuoteId: nil,
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

private actor SuspendedProofSaveStore: PaykitPaymentProofStoring {
    private var proofs: [PendingPaykitPaymentProof]
    private var suspendNext = true
    private var saveWaiter: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var suspended = false

    init(proofs: [PendingPaykitPaymentProof]) {
        self.proofs = proofs
    }

    func load() -> [PendingPaykitPaymentProof] {
        proofs
    }

    func save(_ proofs: [PendingPaykitPaymentProof]) async {
        if suspendNext {
            suspendNext = false
            suspended = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { saveWaiter = $0 }
        }
        self.proofs = proofs
    }

    func waitForSuspendedSave() async {
        if !suspended {
            await withCheckedContinuation { startedWaiter = $0 }
        }
    }

    func resumeSave() {
        saveWaiter?.resume(); saveWaiter = nil
    }
}
