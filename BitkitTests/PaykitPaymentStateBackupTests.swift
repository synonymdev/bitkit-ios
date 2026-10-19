@testable import Bitkit
import BitkitCore
import Combine
import CryptoKit
import Paykit
import VssRustClientFfi
import XCTest

private enum PaykitPaymentStateBackupTestError: Error {
    case restoreFailed
}

final class PaykitPaymentStateBackupTests: XCTestCase {
    private let identity = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

    static let activeAttemptGolden = Data(#"""
    {
      "version": 1,
      "createdAt": 1791234000000,
      "transfers": [],
      "paykitPaymentState": {
        "subscriptions": {},
        "pendingProofs": [
          {
            "identity": "pubkyzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
            "requestId": {
              "paymentRequestId": "550e8400-e29b-41d4-a716-446655440000",
              "counterparty": "pubkyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy",
              "billingPeriodStartsAt": null
            },
            "paymentEndpointIdentifier": "btc-regtest-p2wpkh",
            "paymentAppId": "bitkit",
            "kind": "bitcoin-onchain-txid",
            "paymentStarted": true,
            "paymentIdentifier": "abababababababababababababababababababababababababababababababab",
            "proofData": null,
            "billingPeriod": null,
            "onchainAddress": "bcrt1qoriginal",
            "onchainAmountSats": 1234,
            "onchainWalletId": null,
            "onchainMatchingTransactionIdsBeforeAttempt": [],
            "onchainAcceptanceVerified": false
          }
        ],
        "activeOnchainAttempt": {
          "version": 1,
          "wallet": {
            "kind": "software",
            "network": "regtest",
            "binding": "fe843546f607f38ba7b1e8fe479c3103139ebea5b83628cbaa465e41cf6cb6c0",
            "sourceIndex": "0"
          },
          "attemptId": "550e8400-e29b-41d4-a716-446655440001",
          "requestId": {
            "paymentRequestId": "550e8400-e29b-41d4-a716-446655440000",
            "counterparty": "pubkyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy",
            "billingPeriodStartsAt": null
          },
          "orderId": null,
          "payerIdentity": "pubkyzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
          "address": "bcrt1qoriginal",
          "amountSats": "1234",
          "isMaxAmount": false,
          "status": "unknown",
          "txid": "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
          "rejectionReason": null,
          "originalInputs": [
            {
              "txid": "efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef",
              "vout": "4294967295"
            }
          ],
          "candidateTxids": [
            "abababababababababababababababababababababababababababababababab",
            "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"
          ],
          "feeRateSatsPerVByte": "2",
          "followup": {
            "feeSats": "123",
            "tags": [
              "original tag"
            ],
            "contact": "pubkyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy",
            "createdAtMillis": "1791234000000",
            "channelId": null
          },
          "transfer": null
        }
      }
    }
    """#.utf8) + Data([10])

    private struct LegacyState: Codable {
        let subscriptionsByIdentity: [String: LegacySubscriptionState]
    }

    private struct LegacySubscriptionState: Codable {
        let acceptedAt: [PaykitSubscription.ID: Date]
        let presentedProposalIds: Set<PaykitSubscription.ID>
        let dismissedPaymentIds: Set<PaykitPaymentRequest.ID>
    }

    override func tearDownWithError() throws {
        try Keychain.delete(key: .paykitSubscriptionState)
        try Keychain.delete(key: .paykitPendingPaymentProofs)
        try Keychain.delete(key: .paykitPendingBackupRestore)
        try Keychain.delete(key: .onchainSendAttempts)
        try Keychain.delete(key: .paykitAcceptedPaymentRequests)
        try Keychain.delete(key: .paykitUsdtPayments)
    }

    func testWalletEnvelopePreservesCoreRecoveryData() throws {
        let fixture = #"{"version":1,"createdAt":1,"transfers":[],"usdtWallet":"{\"identity\":\"42161:wallet\",\"transfers\":[]}"}"#
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: Data(fixture.utf8))
        XCTAssertEqual(decoded.usdtWallet, #"{"identity":"42161:wallet","transfers":[]}"#)
        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try JSONDecoder().decode(WalletBackupV1.self, from: encoded).usdtWallet, decoded.usdtWallet)
        let withoutUsdt = #"{"version":1,"createdAt":1,"transfers":[]}"#
        XCTAssertNil(try JSONDecoder().decode(WalletBackupV1.self, from: Data(withoutUsdt.utf8)).usdtWallet)
    }

    @MainActor
    func testRestoredUsdtAttemptsProtectPendingPaymentsAndOnlySatisfiedReceiptsCount() throws {
        let counterparty = "pubky" + String(repeating: "y", count: 52)
        let ids = (0 ..< 4).map { PaykitPaymentRequest.ID(paymentRequestId: "request-\($0)", counterparty: counterparty) }
        let proof = PaykitUsdtPaymentService.Proof(UsdtPaymentProof(chainId: "42161", transactionHash: "transaction",
                                                                    receiptLogIndex: "0", signature: "signature"))
        let attempts = ids.enumerated().map { index, id in
            PaykitUsdtPaymentService.Attempt(quoteId: "quote-\(index)", wallet: "wallet", identity: identity, contact: counterparty,
                                             requestId: id, binding: nil, billingPeriod: nil, proof: index == 2 ? proof : nil,
                                             proofQueued: false, paymentStarted: index == 1)
        }
        let receipts = ids.enumerated().map { index, id in
            PaykitUsdtPaymentService.Receipt(wallet: "wallet", identity: identity, requestId: id, paymentId: "payment-\(index)",
                                             proofEventId: "proof-\(index)", verified: index != 1, transferId: "transfer-\(index)",
                                             amount: PaykitAmount(asset: .usdt, atomic: 5_000_000), receivedAt: Date(),
                                             underpaid: index == 2, afterExpiry: index == 3)
        }
        let service = PaykitUsdtPaymentService()
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: attempts.map(PaykitUsdtStateBackup.Attempt.init),
                                                        receipts: receipts.map(PaykitUsdtStateBackup.Receipt.init)))
        let protection = try service.paymentProtection(identity: identity)
        XCTAssertEqual(protection.inFlight, [ids[1], ids[2]])
        XCTAssertEqual(protection.completed, [ids[2]: .usdt])
        XCTAssertEqual(receipts.filter(\.satisfied).map(\.requestId), [ids[0]])
        XCTAssertTrue(try service.satisfiedProofs(identity: identity).isEmpty, "Restored receipts require the active wallet before use")
        XCTAssertTrue(try service.paymentProtection(identity: counterparty).inFlight.isEmpty)
        XCTAssertTrue(try service.satisfiedProofs(identity: counterparty).isEmpty)
    }

    @MainActor
    func testUnsubmittedUsdtBindingRequiresCurrentJournalEvidenceAfterRestart() async throws {
        let service = PaykitUsdtPaymentService()
        var attempt = unsubmittedUsdtAttempt()
        attempt.paymentStarted = true
        let requestId = try XCTUnwrap(attempt.requestId)
        try saveUsdtAttempts([attempt])
        XCTAssertTrue(service.hasBinding(for: requestId))
        await reconcileUsdt(service)
        XCTAssertFalse(service.hasBinding(for: requestId))

        for context in [("other-wallet", identity), ("wallet", "other-identity")] {
            await service.reconcile(context: { context }, storedTransfer: { _ in nil }, paymentProof: { _, _ in nil },
                                    submitProof: { _ in false }, paymentRequests: { [] }, verifyPayment: { _, _ in nil })
            XCTAssertTrue(service.hasBinding(for: requestId))
        }

        let restarted = PaykitUsdtPaymentService()
        XCTAssertTrue(restarted.hasBinding(for: requestId))
        await reconcileUsdt(restarted)
        XCTAssertFalse(restarted.hasBinding(for: requestId))
        await reconcileUsdt(restarted) { _ in throw PaykitPaymentStateBackupTestError.restoreFailed }
        XCTAssertTrue(restarted.hasBinding(for: requestId))

        for status in [UsdtTransferStatus.pending, .confirmed, .bridging] {
            await reconcileUsdt(restarted)
            XCTAssertFalse(restarted.hasBinding(for: requestId))
            await reconcileUsdt(restarted) { id in
                UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                             recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                             fee: nil, isIncoming: false, status: status, timestamp: 1)
            }
            XCTAssertTrue(restarted.hasBinding(for: requestId))
        }
    }

    @MainActor
    func testTerminalUsdtBindingRequiresCurrentUnexecutedEvidenceWithoutProofs() async throws {
        var attempt = unsubmittedUsdtAttempt()
        attempt.paymentStarted = true
        let requestId = try XCTUnwrap(attempt.requestId)
        for status: UsdtTransferStatus in [.failed, .replaced] {
            let service = PaykitUsdtPaymentService()
            try saveUsdtAttempts([attempt])
            XCTAssertTrue(service.hasBinding(for: requestId))
            await reconcileUsdt(service) { id in
                UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                             recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 0,
                             fee: nil, isIncoming: false, status: status, timestamp: 1)
            }
            XCTAssertFalse(service.hasBinding(for: requestId))
            XCTAssertTrue(PaykitUsdtPaymentService().hasBinding(for: requestId))
            await reconcileUsdt(service)
            XCTAssertFalse(service.hasBinding(for: requestId))
            for hasProof in [false, true] {
                var protected = attempt
                protected.proofQueued = !hasProof
                if hasProof {
                    protected.proof = PaykitUsdtPaymentService.Proof(UsdtPaymentProof(chainId: "42161", transactionHash: "transaction",
                                                                                      receiptLogIndex: "0", signature: "signature"))
                }
                try saveUsdtAttempts([protected])
                await reconcileUsdt(service) { id in
                    UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                                 recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 0,
                                 fee: nil, isIncoming: false, status: status, timestamp: 1)
                }
                XCTAssertTrue(service.hasBinding(for: requestId))
            }
        }
    }

    @MainActor
    func testReconciliationInvalidatesReleaseEvidenceForChangedOrUnreadablePersistence() async throws {
        let service = PaykitUsdtPaymentService()
        let attempt = unsubmittedUsdtAttempt()
        let requestId = try XCTUnwrap(attempt.requestId)
        var started = attempt
        started.paymentStarted = true
        var proved = attempt
        proved.proof = PaykitUsdtPaymentService.Proof(UsdtPaymentProof(chainId: "42161", transactionHash: "transaction",
                                                                       receiptLogIndex: "0", signature: "signature"))
        var queued = attempt
        queued.proofQueued = true
        let replacement = PaykitUsdtPaymentService.Attempt(quoteId: "replacement", wallet: attempt.wallet, identity: identity,
                                                           contact: attempt.contact, requestId: requestId, binding: nil, billingPeriod: nil)
        for changed in [started, proved, queued, replacement] {
            try saveUsdtAttempts([attempt])
            await reconcileUsdt(service)
            XCTAssertFalse(service.hasBinding(for: requestId))
            try saveUsdtAttempts([changed])
            await reconcileUsdt(service) { _ in throw PaykitPaymentStateBackupTestError.restoreFailed }
            XCTAssertTrue(service.hasBinding(for: requestId))
            if changed != replacement {
                await reconcileUsdt(service)
                XCTAssertEqual(service.hasBinding(for: requestId), changed != started)
            }
        }
        try saveUsdtAttempts([attempt])
        await reconcileUsdt(service)
        try Keychain.upsert(key: .paykitUsdtPayments, data: Data("unreadable".utf8))
        XCTAssertTrue(PaykitUsdtPaymentService().hasBinding(for: requestId))
        await reconcileUsdt(service)
        XCTAssertTrue(service.hasBinding(for: requestId))
    }

    @MainActor
    func testUsdtRestoreInvalidatesReleaseEvidenceBeforeReconciliation() async throws {
        let service = PaykitUsdtPaymentService()
        var attempt = unsubmittedUsdtAttempt()
        let requestId = try XCTUnwrap(attempt.requestId)
        try saveUsdtAttempts([attempt])
        await reconcileUsdt(service)
        XCTAssertFalse(service.hasBinding(for: requestId))
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: [.init(attempt)], receipts: []))
        XCTAssertTrue(service.hasBinding(for: requestId))
        XCTAssertTrue(service.resumableRequests.isEmpty)
        await reconcileUsdt(service) { id in
            UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                         recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                         fee: nil, isIncoming: false, status: .pending, timestamp: 1)
        }
        XCTAssertTrue(service.hasBinding(for: requestId))
        await reconcileUsdt(service)
        XCTAssertFalse(service.hasBinding(for: requestId))
        attempt.paymentStarted = true
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: [.init(attempt)], receipts: []))
        XCTAssertTrue(service.hasBinding(for: requestId))
        await reconcileUsdt(service)
        XCTAssertFalse(service.hasBinding(for: requestId))
    }

    @MainActor
    func testUsdtRestoreProtectsAnotherWalletUntilOwnerResolution() async throws {
        let service = PaykitUsdtPaymentService()
        await reconcileUsdt(service)
        let attempt = PaykitUsdtPaymentService.Attempt(quoteId: "restored", wallet: "restored-wallet", identity: identity,
                                                       contact: "counterparty", requestId: .init(
                                                           paymentRequestId: "restored",
                                                           counterparty: "counterparty"
                                                       ),
                                                       binding: nil, billingPeriod: nil, paymentStarted: true)
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: [.init(attempt)], receipts: []))
        for throwsError in [false, true] {
            await service.reconcile(context: {
                if throwsError { throw PaykitPaymentStateBackupTestError.restoreFailed }
                return nil
            }, storedTransfer: { _ in nil }, paymentProof: { _, _ in nil }, submitProof: { _ in false },
            paymentRequests: { [] }, verifyPayment: { _, _ in nil })
            XCTAssertEqual(try service.paymentProtection(identity: identity).inFlight, try [XCTUnwrap(attempt.requestId)])
        }
        await reconcileUsdt(service)
        XCTAssertTrue(try service.paymentProtection(identity: identity).inFlight.isEmpty)
        service.resetForWipe()
        XCTAssertTrue(service.attempts.isEmpty)
        XCTAssertTrue(service.receipts.isEmpty)
        XCTAssertEqual(try service.paymentProtection(identity: identity).inFlight, try [XCTUnwrap(attempt.requestId)])
    }

    @MainActor
    func testUnsubmittedRetryKeepsFailedUsdtRequestPayable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = UsdtWalletManager(storageDirectory: directory, rpcUrl: "http://127.0.0.1:1", bundlerUrl: "http://127.0.0.1:1", loadCredentials: {
            ("test test test test test test test test test test test junk", nil)
        })
        let endpoint = try await wallet.paymentEndpoint()
        let owner = endpoint.value.lowercased()
        let service = PaykitUsdtPaymentService()
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: "retry-request", counterparty: "counterparty")
        let failed = PaykitUsdtPaymentService.Attempt(quoteId: "failed", wallet: owner, identity: identity,
                                                      contact: requestId.counterparty, requestId: requestId, binding: nil,
                                                      billingPeriod: nil, paymentStarted: true)
        try saveUsdtAttempts([failed])
        await service.reconcile(context: { (owner, self.identity) }, storedTransfer: { id in
            UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                         recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                         fee: nil, isIncoming: false, status: .failed, timestamp: 1)
        }, paymentProof: { _, _ in nil }, submitProof: { _ in false }, paymentRequests: { [] }, verifyPayment: { _, _ in nil })
        let retry = PaykitUsdtPaymentService.Attempt(quoteId: "retry", wallet: owner, identity: identity,
                                                     contact: requestId.counterparty, requestId: requestId, binding: nil, billingPeriod: nil)
        try await service.storeAttempt(retry) { id in
            UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                         recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                         fee: nil, isIncoming: false, status: .failed, timestamp: 1)
        }
        XCTAssertTrue(try service.paymentProtection(identity: identity).inFlight.isEmpty)
        let entered = expectation(description: "reconciliation resolving owner")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let reconciliation = Task {
            await service.reconcile(context: {
                entered.fulfill()
                for await _ in gate.stream {
                    break
                }
                return (owner, self.identity)
            }, storedTransfer: { _ in nil }, paymentProof: { _, _ in nil }, submitProof: { _ in false },
            paymentRequests: { [] }, verifyPayment: { _, _ in nil })
        }
        await fulfillment(of: [entered], timeout: 2)
        let quote = UsdtQuote(bridgeProvider: nil, id: "retry", recipient: owner, destination: .arbitrum,
                              amount: 50000, receivedAmount: 50000, maximumFee: 100, expiresAt: UInt64(Date().timeIntervalSince1970) + 100)
        do {
            try await service.send(quote, context: ContactPaymentContext(publicKey: requestId.counterparty), paymentTerms: nil, wallet: wallet) {
                gate.continuation.yield(())
                await reconciliation.value
                XCTAssertEqual(try service.paymentProtection(identity: self.identity).inFlight, [requestId])
                throw CancellationError()
            }
            XCTFail("Authorization cancellation must stop the send")
        } catch is CancellationError {}
        XCTAssertTrue(try service.paymentProtection(identity: identity).inFlight.isEmpty)
        XCTAssertFalse(service.attempts.first { $0.quoteId == "retry" }?.paymentStarted ?? true)
    }

    @MainActor
    func testInterruptedReconciliationPreservesOnlyCurrentOwnerFailureEvidence() async throws {
        for reason in ["missing", "error", "cancel", "restore", "wipe", "other-wallet", "pending"] {
            let service = PaykitUsdtPaymentService()
            var attempt = unsubmittedUsdtAttempt()
            attempt.paymentStarted = true
            let requestId = try XCTUnwrap(attempt.requestId)
            try saveUsdtAttempts([attempt])
            await reconcileUsdt(service) { id in UsdtTransfer(
                sender: nil,
                id: id,
                txHash: nil,
                userOperationHash: nil,
                bridgeGuid: nil,
                orchestra: nil,
                recipient: "recipient",
                destination: .arbitrum,
                amount: 50000,
                receivedAmount: 50000,
                fee: nil,
                isIncoming: false,
                status: .failed,
                timestamp: 1
            ) }
            XCTAssertEqual(service.resumableRequests, [requestId])
            await service.reconcile(context: {
                switch reason {
                case "missing": return nil
                case "error": throw PaykitPaymentStateBackupTestError.restoreFailed
                case "cancel": throw CancellationError()
                case "restore":
                    try service.restoreBackup(service.backupSnapshot())
                    return nil
                case "wipe":
                    service.resetForWipe()
                    return nil
                case "other-wallet": return ("another-wallet", self.identity)
                default: return ("wallet", self.identity)
                }
            }, storedTransfer: { id in UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                                                    recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                                                    fee: nil, isIncoming: false, status: .pending, timestamp: 1) }, paymentProof: { _, _ in nil },
            submitProof: { _ in false }, paymentRequests: { [] }, verifyPayment: { _, _ in nil })
            XCTAssertEqual(service.resumableRequests.contains(requestId), ["missing", "error", "cancel"].contains(reason), reason)
        }
    }

    @MainActor
    func testUsdtRestoreInvalidatesSuspendedReconciliationEvidence() async throws {
        let service = PaykitUsdtPaymentService()
        let attempt = unsubmittedUsdtAttempt()
        let requestId = try XCTUnwrap(attempt.requestId)
        try saveUsdtAttempts([attempt])
        let entered = expectation(description: "journal read started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let reconciliation = Task {
            await reconcileUsdt(service) { _ in
                entered.fulfill()
                for await _ in gate.stream {
                    break
                }
                return nil
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: [.init(attempt)], receipts: []))
        gate.continuation.yield(())
        gate.continuation.finish()
        await reconciliation.value
        XCTAssertTrue(service.hasBinding(for: requestId))
        XCTAssertTrue(service.resumableRequests.isEmpty)
        await reconcileUsdt(service)
        XCTAssertFalse(service.hasBinding(for: requestId))
    }

    @MainActor
    func testUsdtProtectionRefreshesAfterDefiniteFailureWithoutHidingAnotherPeriod() async throws {
        let period = PaykitBillingPeriod(startsAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         endsAt: Date(timeIntervalSince1970: 1_800_086_400))
        let id = PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "counterparty",
                                         billingPeriodStartsAt: period.startsAt)
        let attempt = PaykitUsdtPaymentService.Attempt(quoteId: "quote", wallet: "wallet", identity: identity,
                                                       contact: id.counterparty, requestId: id, binding: nil,
                                                       billingPeriod: period, paymentStarted: true)
        let otherWallet = PaykitUsdtPaymentService.Attempt(quoteId: "other", wallet: "other-wallet", identity: identity,
                                                           contact: id.counterparty, requestId: .init(
                                                               paymentRequestId: "other",
                                                               counterparty: id.counterparty
                                                           ),
                                                           binding: nil, billingPeriod: nil, paymentStarted: true)
        let service = PaykitUsdtPaymentService()
        var changes = 0
        var backupChanges = 0
        let observation = PaykitUsdtPaymentService.paymentProtectionChangedPublisher.sink { changes += 1 }
        let backupObservation = PaykitUsdtPaymentService.walletBackupDataChangedPublisher.sink { backupChanges += 1 }
        defer { observation.cancel(); backupObservation.cancel() }
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: [attempt, otherWallet].map(PaykitUsdtStateBackup.Attempt.init), receipts: []))
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(backupChanges, 1)
        changes = 0
        backupChanges = 0
        await reconcileUsdt(service, storedTransfer: { quoteId in
            UsdtTransfer(sender: nil, id: quoteId, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                         recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                         fee: nil, isIncoming: false, status: .pending, timestamp: 1)
        })
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(backupChanges, 0)
        XCTAssertEqual(try service.paymentProtection(identity: identity).inFlight, [id])
        let next = PaykitPaymentRequest.ID(paymentRequestId: id.paymentRequestId, counterparty: id.counterparty,
                                           billingPeriodStartsAt: period.endsAt)
        XCTAssertFalse(try service.paymentProtection(identity: identity).inFlight.contains(next))
        changes = 0
        await reconcileUsdt(service, storedTransfer: { quoteId in
            UsdtTransfer(sender: nil, id: quoteId, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                         recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                         fee: nil, isIncoming: false, status: .failed, timestamp: 1)
        })
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(backupChanges, 0)
        XCTAssertTrue(try service.paymentProtection(identity: identity).inFlight.isEmpty)
        XCTAssertEqual(service.resumableRequests, [id])
        changes = 0
        await reconcileUsdt(service, storedTransfer: { quoteId in
            XCTAssertEqual(try service.paymentProtection(identity: self.identity).inFlight, [id])
            return UsdtTransfer(sender: nil, id: quoteId, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                                recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                                fee: nil, isIncoming: false, status: .failed, timestamp: 1)
        })
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(backupChanges, 0)
    }

    @MainActor
    private func unsubmittedUsdtAttempt() -> PaykitUsdtPaymentService.Attempt {
        let id = PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "counterparty")
        return PaykitUsdtPaymentService.Attempt(quoteId: "quote", wallet: "wallet", identity: identity, contact: id.counterparty,
                                                requestId: id, binding: nil, billingPeriod: nil)
    }

    @MainActor
    func testAllRestoredAttemptsProtectTheSameRequestRegardlessOfOrder() async throws {
        let unstarted = unsubmittedUsdtAttempt()
        let started = PaykitUsdtPaymentService.Attempt(quoteId: "started", wallet: unstarted.wallet, identity: identity,
                                                       contact: unstarted.contact, requestId: unstarted.requestId,
                                                       binding: nil, billingPeriod: nil, paymentStarted: true)
        let replacement = PaykitUsdtPaymentService.Attempt(quoteId: "replacement", wallet: unstarted.wallet, identity: identity,
                                                           contact: unstarted.contact, requestId: unstarted.requestId,
                                                           binding: nil, billingPeriod: nil)
        for status: UsdtTransferStatus in [.pending, .confirmed, .failed, .replaced] {
            for attempts in [[unstarted, started], [started, unstarted]] {
                try saveUsdtAttempts([])
                let service = PaykitUsdtPaymentService()
                let backup = PaykitUsdtStateBackup(attempts: attempts.map(PaykitUsdtStateBackup.Attempt.init), receipts: [])
                try service.restoreBackup(backup)
                try service.restoreBackup(backup)
                let history: (String) async throws -> UsdtTransfer? = { id in
                    guard id == started.quoteId else { return nil }
                    return UsdtTransfer(sender: nil, id: id, txHash: nil, userOperationHash: nil, bridgeGuid: nil, orchestra: nil,
                                        recipient: "recipient", destination: .arbitrum, amount: 50000, receivedAmount: 50000,
                                        fee: nil, isIncoming: false, status: status, timestamp: 1)
                }
                await reconcileUsdt(service, storedTransfer: history)
                let canReplace = status == .failed || status == .replaced
                XCTAssertEqual(service.resumableRequests.isEmpty, !canReplace)
                do {
                    try await service.storeAttempt(replacement, storedTransfer: history)
                    XCTAssertTrue(canReplace)
                    XCTAssertEqual(try service.backupSnapshot().attempts.map { try $0.restored() }, [started, replacement])
                } catch {
                    XCTAssertFalse(canReplace)
                    XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
                    XCTAssertEqual(try service.backupSnapshot().attempts.map { try $0.restored() }, attempts)
                }
            }
        }
    }

    @MainActor
    func testPreparingTheSameQuotePreservesProofAndRestoredProgress() async throws {
        let attempt = unsubmittedUsdtAttempt()
        var funded = attempt
        funded.paymentStarted = true
        funded.proof = .init(UsdtPaymentProof(chainId: "42161", transactionHash: "transaction", receiptLogIndex: "0", signature: "signature"))
        try saveUsdtAttempts([funded])
        let service = PaykitUsdtPaymentService()
        try await service.storeAttempt(attempt, storedTransfer: { _ in nil })
        XCTAssertEqual(try service.backupSnapshot().attempts.map { try $0.restored() }, [funded])
        let replacement = PaykitUsdtPaymentService.Attempt(quoteId: "replacement", wallet: attempt.wallet, identity: identity,
                                                           contact: attempt.contact, requestId: attempt.requestId,
                                                           binding: nil, billingPeriod: nil)
        do {
            try await service.storeAttempt(replacement, storedTransfer: { _ in nil })
            XCTFail("A payment proof must retain its request binding")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
        }
        XCTAssertEqual(try service.backupSnapshot().attempts.map { try $0.restored() }, [funded])
    }

    @MainActor
    func testRestoreDuringReplacementKeepsEveryAttempt() async throws {
        let attempt = unsubmittedUsdtAttempt()
        try saveUsdtAttempts([attempt])
        let service = PaykitUsdtPaymentService()
        let replacement = PaykitUsdtPaymentService.Attempt(quoteId: "replacement", wallet: attempt.wallet, identity: identity,
                                                           contact: attempt.contact, requestId: attempt.requestId,
                                                           binding: nil, billingPeriod: nil)
        var restored = replacement
        restored.paymentStarted = true
        do {
            try await service.storeAttempt(replacement) { _ in
                try service.restoreBackup(PaykitUsdtStateBackup(attempts: [.init(restored)], receipts: []))
                return nil
            }
            XCTFail("Changed payment state must invalidate the replacement")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
        }
        XCTAssertEqual(try service.backupSnapshot().attempts.map { try $0.restored() }, [attempt, restored])
    }

    @MainActor
    private func saveUsdtAttempts(_ attempts: [PaykitUsdtPaymentService.Attempt]) throws {
        struct State: Encodable {
            let attempts: [PaykitUsdtPaymentService.Attempt]
            let receipts: [PaykitUsdtPaymentService.Receipt] = []
        }
        try Keychain.upsert(key: .paykitUsdtPayments, data: JSONEncoder().encode(State(attempts: attempts)))
    }

    @MainActor
    private func reconcileUsdt(_ service: PaykitUsdtPaymentService,
                               storedTransfer: (String) async throws -> UsdtTransfer? = { _ in nil }) async
    {
        await service.reconcile(context: { ("wallet", self.identity) }, storedTransfer: storedTransfer,
                                paymentProof: { _, _ in nil }, submitProof: { _ in false }, paymentRequests: { [] },
                                verifyPayment: { _, _ in nil })
    }

    func testWalletBackupWritesWaitForEarlierUploadAndRecoverAfterFailure() async throws {
        let writer = WalletBackupWriter()
        let entered = expectation(description: "upload started")
        let gate = AsyncStream<Void>.makeStream()
        let events = BackupWriteEvents()
        let first = Task {
            try await writer.write {
                entered.fulfill()
                for await _ in gate.stream {
                    break
                }
                await events.append(1)
                throw PaykitPaymentStateBackupTestError.restoreFailed
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await writer.write { await events.append(2) } }
        gate.continuation.yield(())
        gate.continuation.finish()
        do { try await first.value; XCTFail("Upload should fail") } catch {}
        try await second.value
        let recorded = await events.values
        XCTAssertEqual(recorded, [1, 2])
    }

    func testSharedBackupBindingUsesActualVssDerivationAndNetworkNames() throws {
        let mnemonic = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        var bindings: [String: String] = [:]
        for network in ["bitcoin", "testnet", "signet", "regtest"] {
            let storeId = try vssDeriveStoreId(prefix: "bitkit_v1_" + network, mnemonic: mnemonic, passphrase: nil)
            let binding = SHA256.hash(data: Data(storeId.utf8)).map { String(format: "%02x", $0) }.joined()
            bindings[network] = binding
        }
        XCTAssertEqual(bindings, [
            "bitcoin": "28f258542d91310274942356e7777d8978bac6dbd3fadbfbfe5d663b19f1f6c5",
            "testnet": "0ce1e7952991cf5ce84bfa135dbc194b3d55a7f2fc69807091c4ca1d6eaac809",
            "signet": "966319adba79fb70afbf6eb1c7bde0cf93433e08d6f2f832c30467b812005fbe",
            "regtest": "fe843546f607f38ba7b1e8fe479c3103139ebea5b83628cbaa465e41cf6cb6c0",
        ])
        try print("BI717_SHARED_BINDING_VECTOR " + String(decoding: JSONEncoder().encode(bindings), as: UTF8.self))
        XCTAssertEqual(Env.vssStoreIdPrefix, "bitkit_v1_" + Env.networkName)
    }

    static func completeAttemptGolden() throws -> Data {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: activeAttemptGolden) as? [String: Any])
        var state = try XCTUnwrap(envelope["paykitPaymentState"] as? [String: Any])
        var attempt = try XCTUnwrap(state["activeOnchainAttempt"] as? [String: Any])
        attempt["candidateFeeRates"] = [String(repeating: "ab", count: 32): "2", String(repeating: "cd", count: 32): "4"]
        state["activeOnchainAttempt"] = attempt
        envelope["paykitPaymentState"] = state
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    static let goldenBinding = "fe843546f607f38ba7b1e8fe479c3103139ebea5b83628cbaa465e41cf6cb6c0"

    static func goldenWallet(index: Int = 2) -> PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet {
        .init(kind: "software", network: "regtest", binding: goldenBinding, sourceIndex: String(index))
    }

    func testSharedGoldenRestoreRemapsOnlyOriginalWalletAndResetsLocalFollowup() throws {
        let digest = SHA256.hash(data: Self.activeAttemptGolden).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "42bd135dbc91aa0b2004f2633f6f8b28c46dddf8da3c6f949cf2ff036c07e0a6")
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let state = try XCTUnwrap(envelope.paykitPaymentState)
        let wire = try XCTUnwrap(state.activeOnchainAttempt)
        let proofs = try state.pendingProofs.map { try $0.restored() }
        let restored = try wire.restored(wallet: Self.goldenWallet(), proofs: proofs)
        XCTAssertEqual(restored.0.walletId, "node:regtest:" + WalletScope.default + ":2")
        XCTAssertEqual(restored.0.recoveryContext?.candidateTxids, [String(repeating: "ab", count: 32), String(repeating: "cd", count: 32)])
        XCTAssertEqual(restored.0.recoveryContext?.inputs.first?.vout, UInt32.max)
        XCTAssertEqual(restored.0.amountSats, 1234)
        XCTAssertFalse(restored.0.localFollowupComplete)
        XCTAssertTrue(restored.0.canRetrySamePayment)
        XCTAssertNil(restored.1.first?.onchainWalletId, "Software proof must not be remapped to a hardware scope")
        XCTAssertEqual(restored.1.first?.onchainLocalFollowupComplete, false)
        let remappedWire = try PaykitPaymentStateBackup.ActiveOnchainAttempt(restored.0, wallet: Self.goldenWallet())
        let again = try remappedWire.restored(wallet: Self.goldenWallet(), proofs: proofs)
        XCTAssertEqual(again.0, restored.0)
    }

    func testRecurringActiveAttemptPreservesExactBillingTimestamp() async throws {
        for timestamp in ["2026-09-24T10:00:00.100Z", "2026-09-24T10:00:00.123456789Z"] {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.completeAttemptGolden()) as? [String: Any])
            var state = try XCTUnwrap(envelope["paykitPaymentState"] as? [String: Any])
            var active = try XCTUnwrap(state["activeOnchainAttempt"] as? [String: Any])
            var request = try XCTUnwrap(active["requestId"] as? [String: Any])
            request["billingPeriodStartsAt"] = timestamp
            active["requestId"] = request
            var proofs = try XCTUnwrap(state["pendingProofs"] as? [[String: Any]])
            proofs[0]["requestId"] = request
            proofs[0]["billingPeriod"] = ["startsAt": timestamp, "endsAt": "2026-09-25T10:00:00.123456789Z"]
            state["activeOnchainAttempt"] = active
            state["pendingProofs"] = proofs
            envelope["paykitPaymentState"] = state
            let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: JSONSerialization.data(withJSONObject: envelope))
            let paymentState = try XCTUnwrap(decoded.paykitPaymentState)
            let restoredProofs = try paymentState.pendingProofs.map { try $0.restored() }
            let attempt = try XCTUnwrap(paymentState.activeOnchainAttempt).restored(
                wallet: Self.goldenWallet(), proofs: restoredProofs
            ).0
            let store = MemoryAttemptStore()
            try store.save([attempt])
            let service = OnchainSendAttemptService(store: store)
            let backup = try await service.backupSnapshot(wallet: Self.goldenWallet(), proofs: restoredProofs)
            let snapshot = try XCTUnwrap(backup)
            XCTAssertEqual(snapshot.requestId?.billingPeriodStartsAt, timestamp)
            XCTAssertEqual(snapshot.requestId?.billingPeriodStartsAt, paymentState.pendingProofs.first?.requestId.billingPeriodStartsAt)
        }
    }

    func testHardwareBackupRequiresCompleteSignedReceipt() throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let proof = try XCTUnwrap(envelope.paykitPaymentState?.pendingProofs.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as? [String: Any])
        let signed = "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300"
        object["hardwareSignedTransaction"] = signed
        object["paymentIdentifier"] = try SignedTransactionId.fromHex(signed)
        object["onchainWalletId"] = "trezor:backup-wallet"
        object["hardwareMiningFeeSats"] = 141
        object["hardwareFeeRate"] = 2
        object["hardwareTotalSpent"] = 1375
        let complete = try JSONDecoder().decode(PaykitPaymentStateBackup.Proof.self, from: JSONSerialization.data(withJSONObject: object))
        let restored = try complete.restored()
        XCTAssertEqual(restored.hardwareSignedTransaction, signed)
        XCTAssertEqual(restored.hardwareMiningFeeSats, 141)
        XCTAssertEqual(restored.hardwareFeeRate, 2)
        XCTAssertEqual(restored.hardwareTotalSpent, 1375)
        for field in ["hardwareMiningFeeSats", "hardwareFeeRate", "hardwareTotalSpent"] {
            for missing in [true, false] {
                var incomplete = object
                if missing {
                    incomplete.removeValue(forKey: field)
                } else {
                    incomplete[field] = NSNull()
                }
                let wire = try JSONDecoder().decode(PaykitPaymentStateBackup.Proof.self, from: JSONSerialization.data(withJSONObject: incomplete))
                XCTAssertThrowsError(try wire.restored(), field)
            }
        }
    }

    func testSharedGoldenRejectsWrongWalletNetworkPayerAndMalformedReceipt() throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let state = try XCTUnwrap(envelope.paykitPaymentState)
        let wire = try XCTUnwrap(state.activeOnchainAttempt)
        let proofs = try state.pendingProofs.map { try $0.restored() }
        for destination in [
            PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
                kind: "software",
                network: "regtest",
                binding: String(repeating: "a", count: 64),
                sourceIndex: "2"
            ),
            .init(kind: "software", network: "bitcoin", binding: Self.goldenBinding, sourceIndex: "2"),
            .init(kind: "software", network: "regtest", binding: Self.goldenBinding, sourceIndex: "-1"),
        ] {
            XCTAssertThrowsError(try wire.restored(wallet: destination, proofs: proofs))
        }
        var foreignProof = try XCTUnwrap(proofs.first)
        foreignProof = PendingPaykitPaymentProof(identity: "pubky" + String(repeating: "y", count: 52), requestId: foreignProof.requestId,
                                                 paymentAppId: "bitkit", paymentEndpointIdentifier: foreignProof.paymentEndpointIdentifier,
                                                 kind: .onchain,
                                                 paymentStarted: true, paymentIdentifier: foreignProof.paymentIdentifier, proofData: nil,
                                                 onchainAddress: foreignProof.onchainAddress, onchainAmountSats: foreignProof.onchainAmountSats)
        XCTAssertThrowsError(try wire.restored(wallet: Self.goldenWallet(), proofs: [foreignProof]))
        foreignProof = try XCTUnwrap(proofs.first)
        foreignProof.onchainWalletId = "trezor:foreign"
        XCTAssertThrowsError(try wire.restored(wallet: Self.goldenWallet(), proofs: [foreignProof]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        for patch: [String: Any] in [
            ["amountSats": "18446744073709551616"], ["amountSats": "01"], ["feeRateSatsPerVByte": "4294967296"],
            ["candidateTxids": [String(repeating: "ab", count: 32), String(repeating: "ab", count: 32)]],
            ["txid": String(repeating: "ef", count: 32)], ["version": 2],
        ] {
            let bad = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                               from: JSONSerialization.data(withJSONObject: object.merging(patch) { _, new in new }))
            XCTAssertThrowsError(try bad.restored(wallet: Self.goldenWallet(), proofs: proofs))
        }
    }

    func testRestoredCandidateFeesAndTransferAmountAreConsistent() throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let wire = try XCTUnwrap(envelope.paykitPaymentState?.activeOnchainAttempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        let original = try XCTUnwrap(wire.candidateTxids.first)
        let successor = try XCTUnwrap(wire.candidateTxids.last)
        let later = String(repeating: "12", count: 32)
        object["requestId"] = nil
        object["payerIdentity"] = nil
        object["txid"] = original
        object["candidateTxids"] = [original, successor, later]
        func restored(_ fields: [String: Any]) throws -> OnchainSendAttempt {
            let backup = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                                  from: JSONSerialization.data(withJSONObject: fields))
            return try backup.restored(wallet: Self.goldenWallet(), proofs: []).0
        }
        for status in ["pending", "unknown", "rejected", "accepted"] {
            object["status"] = status
            for rates: [String: String]? in [nil, [:], [successor: "4"], [later: "5"],
                                             [original: "3", successor: "4", later: "5"]]
            {
                object["candidateFeeRates"] = rates
                XCTAssertThrowsError(try restored(object))
            }
            for rates in [[successor: "4", later: "5"], [original: "2", successor: "4", later: "5"]] {
                object["candidateFeeRates"] = rates
                let attempt = try restored(object)
                XCTAssertEqual(attempt.recoveryContext?.feeRate(for: original), 2)
                XCTAssertEqual(attempt.recoveryContext?.feeRate(for: successor), 4)
                XCTAssertEqual(attempt.recoveryContext?.feeRate(for: later), 5)
            }
        }
        object["status"] = "unknown"
        object["orderId"] = "original-order"
        object["transfer"] = ["txTotalSats": "2000", "preTransferOnchainSats": "3000",
                              "originalOrderClientBalanceSats": "900", "originalOrderFeeSats": "1000"]
        for amount in ["999", "1001", "1234"] {
            object["amountSats"] = amount
            XCTAssertThrowsError(try restored(object))
        }
        object["amountSats"] = "1000"
        var understated = object
        understated["transfer"] = ["txTotalSats": "1", "preTransferOnchainSats": "3000",
                                   "originalOrderClientBalanceSats": "900", "originalOrderFeeSats": "1000"]
        XCTAssertThrowsError(try restored(understated))
        let attempt = try restored(object)
        XCTAssertEqual(attempt.amountSats, 1000)
        XCTAssertEqual(attempt.transferContext?.originalOrderFeeSats, attempt.amountSats)
    }

    func testSendAllFundingBackupPreservesActualAmountAndOriginalOrderTerms() throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let wire = try XCTUnwrap(envelope.paykitPaymentState?.activeOnchainAttempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        object["requestId"] = nil
        object["payerIdentity"] = nil
        object["orderId"] = "original-order"
        object["isMaxAmount"] = true
        object["amountSats"] = "99500"
        object["transfer"] = ["txTotalSats": "100000", "preTransferOnchainSats": "100000",
                              "originalOrderClientBalanceSats": "97000", "originalOrderFeeSats": "99000"]
        func restored(_ fields: [String: Any]) throws -> OnchainSendAttempt {
            let backup = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                                  from: JSONSerialization.data(withJSONObject: fields))
            return try backup.restored(wallet: Self.goldenWallet(), proofs: []).0
        }
        for status in ["pending", "unknown", "rejected", "accepted"] {
            object["status"] = status
            let attempt = try restored(object)
            XCTAssertEqual(attempt.amountSats, 99500)
            XCTAssertEqual(attempt.transferContext?.originalOrderFeeSats, 99000)
            let encoded = try PaykitPaymentStateBackup.ActiveOnchainAttempt(attempt, wallet: Self.goldenWallet())
            let roundTrip = try encoded.restored(wallet: Self.goldenWallet(), proofs: []).0
            XCTAssertEqual(roundTrip.amountSats, 99500)
            XCTAssertEqual(roundTrip.transferContext, attempt.transferContext)
        }
        for amount in ["98999", "100001"] {
            object["amountSats"] = amount
            XCTAssertThrowsError(try restored(object))
        }
        object["amountSats"] = "99500"
        object["isMaxAmount"] = false
        XCTAssertThrowsError(try restored(object))
    }

    func testCandidateFeeRatesRoundtripAndRejectForeignOrMalformedRates() throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let state = try XCTUnwrap(envelope.paykitPaymentState)
        let wire = try XCTUnwrap(state.activeOnchainAttempt)
        let proofs = try state.pendingProofs.map { try $0.restored() }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        let original = String(repeating: "ab", count: 32)
        let successor = String(repeating: "cd", count: 32)
        var patched = object
        patched["candidateFeeRates"] = [original: "2", successor: "4"]
        let current = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                               from: JSONSerialization.data(withJSONObject: patched))
        let restored = try current.restored(wallet: Self.goldenWallet(), proofs: proofs).0
        XCTAssertEqual(restored.recoveryContext?.feeRate(for: original), 2)
        XCTAssertEqual(restored.recoveryContext?.feeRate(for: successor), 4)
        let again = try PaykitPaymentStateBackup.ActiveOnchainAttempt(restored, wallet: Self.goldenWallet())
        XCTAssertEqual(again.candidateFeeRates, [original: "2", successor: "4"])
        let incomplete = try JSONDecoder().decode(WalletBackupV1.self, from: Self.activeAttemptGolden)
        XCTAssertThrowsError(try XCTUnwrap(incomplete.paykitPaymentState?.activeOnchainAttempt)
            .restored(wallet: Self.goldenWallet(), proofs: proofs))
        for values in [[successor: "0"], [successor: "4294967296"], [successor: "01"], [String(repeating: "ef", count: 32): "4"],
                       [successor.uppercased(): "4"]]
        {
            patched["candidateFeeRates"] = values
            let bad = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                               from: JSONSerialization.data(withJSONObject: patched))
            XCTAssertThrowsError(try bad.restored(wallet: Self.goldenWallet(), proofs: proofs))
        }
    }

    func testAcceptedSuccessorBackupRequiresItsFeeRate() throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let state = try XCTUnwrap(envelope.paykitPaymentState)
        let wire = try XCTUnwrap(state.activeOnchainAttempt)
        let proofs = try state.pendingProofs.map { try $0.restored() }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        let original = try XCTUnwrap(wire.candidateTxids.first)
        let successor = try XCTUnwrap(wire.candidateTxids.last)
        object["status"] = "accepted"
        object["txid"] = successor
        for rates: [String: String]? in [nil, [:], [original: "2"]] {
            object["candidateFeeRates"] = rates
            let backup = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                                  from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try backup.restored(wallet: Self.goldenWallet(), proofs: proofs))
        }
        object["candidateFeeRates"] = [successor: "4"]
        let valid = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try valid.restored(wallet: Self.goldenWallet(), proofs: proofs).0.recoveryContext?.feeRate(for: successor), 4)
        object["candidateFeeRates"] = [successor: "4"]
        object["txid"] = original
        let firstWinner = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                                   from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try firstWinner.restored(wallet: Self.goldenWallet(), proofs: proofs).0.recoveryContext?.feeRate(for: original), 2)
    }

    func testAcceptedBackupRequiresMatchingVerifiedProofData() throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let state = try XCTUnwrap(envelope.paykitPaymentState)
        let wire = try XCTUnwrap(state.activeOnchainAttempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        object["status"] = "accepted"
        object["candidateFeeRates"] = try [XCTUnwrap(wire.txid): "4"]
        let accepted = try JSONDecoder().decode(PaykitPaymentStateBackup.ActiveOnchainAttempt.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        var proof = try XCTUnwrap(state.pendingProofs.first).restored()
        proof.paymentIdentifier = accepted.txid
        proof.proofData = accepted.txid
        proof.onchainAcceptanceVerified = true
        _ = try accepted.restored(wallet: Self.goldenWallet(), proofs: [proof])
        proof.proofData = String(repeating: "ab", count: 32)
        XCTAssertThrowsError(try accepted.restored(wallet: Self.goldenWallet(), proofs: [proof]))
    }

    func testAndroidMillisecondFollowupRestoresAndPreservesWireProvenance() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.completeAttemptGolden()) as? [String: Any])
        var state = try XCTUnwrap(object["paykitPaymentState"] as? [String: Any])
        var active = try XCTUnwrap(state["activeOnchainAttempt"] as? [String: Any])
        var followup = try XCTUnwrap(active["followup"] as? [String: Any])
        followup["createdAtMillis"] = "1791234000123"
        active["followup"] = followup
        state["activeOnchainAttempt"] = active
        object["paykitPaymentState"] = state
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: JSONSerialization.data(withJSONObject: object))
        let paymentState = try XCTUnwrap(decoded.paykitPaymentState)
        let proofs = try paymentState.pendingProofs.map { try $0.restored() }
        let restored = try XCTUnwrap(paymentState.activeOnchainAttempt).restored(wallet: Self.goldenWallet(), proofs: proofs).0
        XCTAssertEqual(restored.followupContext?.createdAt, 1_791_234_000)
        XCTAssertEqual(restored.followupContext?.backupCreatedAtMillis, 1_791_234_000_123)
        let again = try PaykitPaymentStateBackup.ActiveOnchainAttempt(restored, wallet: Self.goldenWallet())
        XCTAssertEqual(again.followup?.createdAtMillis, "1791234000123")
    }

    func testRestoreCannotClobberDifferentUnresolvedOriginalOperation() async throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: Self.completeAttemptGolden())
        let state = try XCTUnwrap(envelope.paykitPaymentState)
        let restored = try XCTUnwrap(state.activeOnchainAttempt).restored(
            wallet: Self.goldenWallet(), proofs: state.pendingProofs.map { try $0.restored() }
        ).0
        let store = MemoryAttemptStore()
        let existing = OnchainSendAttempt(id: UUID(), walletId: restored.walletId, requestId: nil, orderId: nil,
                                          address: "another original", amountSats: 9999, isMaxAmount: false, status: .unknown)
        try store.save([existing])
        let service = OnchainSendAttemptService(store: store)
        do { try await service.restoreBackup(restored); XCTFail("Restore overwrote unresolved local operation") } catch {}
        XCTAssertEqual(store.snapshot(), [existing])
        do { try await service.restoreBackup(nil); XCTFail("Absent backup guard erased unresolved local operation") } catch {}
        XCTAssertEqual(store.snapshot(), [existing])

        var local = restored
        let candidate = try XCTUnwrap(local.recoveryContext?.candidateTxids.last)
        local.recoveryContext?.candidateFeeSats = [candidate: 281]
        try store.save([local])
        let replay = OnchainSendAttemptService(store: store)
        try await replay.restoreBackup(restored)
        XCTAssertEqual(store.snapshot(), [local], "Identical backup replay must retain local fee evidence")
        var incoming = restored
        incoming.recoveryContext?.candidateFeeSats = [candidate: 999]
        try await replay.restoreBackup(incoming)
        XCTAssertEqual(store.snapshot(), [local], "Backup replay must not import fee metadata")

        var differentCandidates = restored
        differentCandidates.recoveryContext?.candidateTxids.append(String(repeating: "ef", count: 32))
        var differentProgress = restored
        differentProgress.localFollowupComplete.toggle()
        for changed in [differentCandidates, differentProgress] {
            do { try await replay.restoreBackup(changed); XCTFail("Restore replaced different candidate or progress state") } catch {}
            XCTAssertEqual(store.snapshot(), [local])
        }
    }

    func testWalletEnvelopeRetainsActiveAttemptWireAcrossDecodeAndEncode() throws {
        let receipt: [String: Any] = [
            "version": 1,
            "wallet": ["kind": "software", "network": "regtest", "binding": String(repeating: "a", count: 64), "sourceIndex": "0"],
            "attemptId": UUID().uuidString.lowercased(), "address": "bcrt1qoriginal", "amountSats": "20000",
            "isMaxAmount": true, "status": "unknown", "txid": String(repeating: "ab", count: 32),
            "originalInputs": [["txid": String(repeating: "cd", count: 32), "vout": "0"]],
            "candidateTxids": [String(repeating: "ab", count: 32)], "feeRateSatsPerVByte": "2",
            "followup": ["feeSats": "100", "tags": ["original"], "createdAtMillis": "1000"],
        ]
        let envelope: [String: Any] = ["version": 1, "createdAt": 1000, "transfers": [],
                                       "paykitPaymentState": ["subscriptions": [:], "pendingProofs": [], "activeOnchainAttempt": receipt]]
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: JSONSerialization.data(withJSONObject: envelope))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let state = try XCTUnwrap(encoded["paykitPaymentState"] as? [String: Any])
        XCTAssertNotNil(state["activeOnchainAttempt"], "Wallet backup dropped original prepared inputs/candidate identity")
    }

    func testPaymentStateBackupRoundTrip() async throws {
        let id = PaykitSubscription.ID(paymentRequestId: "subscription", counterparty: identity)
        let period = try XCTUnwrap(PaykitBillingPeriod(sdkPeriod: BillingPeriod(
            startsAt: "2026-09-24T10:00:00.100Z", endsAt: "2026-09-25T10:00:00.100Z"
        )))
        let startedAt = period.startsAt
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: id.paymentRequestId,
            counterparty: id.counterparty,
            billingPeriodStartsAt: startedAt
        )
        let subscriptions = PaykitSubscriptionState(
            acceptedAt: [id: PaykitPreciseInstant(date: startedAt)],
            presentedProposalIds: [id]
        )
        let proof = PendingPaykitPaymentProof(
            identity: identity,
            requestId: requestId,
            paymentAppId: "bitkit",
            paymentEndpointIdentifier: "bitcoin-onchain",
            kind: .onchain,
            billingPeriod: period,
            paymentStarted: true,
            paymentIdentifier: "transaction-id",
            proofData: "transaction-id",
            conversionQuoteId: "quote",
            onchainAddress: "test-address",
            onchainAmountSats: 1000,
            onchainWalletId: "trezor:android",
            onchainMatchingTransactionIdsBeforeAttempt: ["previous-transaction"],
            onchainAcceptanceVerified: true
        )
        let acceptedId = PaykitPaymentRequest.ID(paymentRequestId: "one-time", counterparty: identity)
        let acceptanceStore = PaykitPaymentRequestIdStore(key: .paykitAcceptedPaymentRequests)
        try acceptanceStore.save([acceptedId], identity: identity)
        let backup = try PaykitPaymentStateBackup(
            subscriptions: [identity: .init(subscriptions)],
            pendingProofs: [.init(proof)],
            acceptedOneTimeRequests: acceptanceStore.backupSnapshot()
        )
        let data = try JSONEncoder().encode(backup)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"onchainAcceptanceVerified\":true"))
        XCTAssertFalse(json.contains("onchainBroadcastAccepted"))
        let decoded = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: data)
        XCTAssertEqual(decoded.pendingProofs.first?.requestId.billingPeriodStartsAt, "2026-09-24T10:00:00.100Z")
        XCTAssertEqual(decoded.pendingProofs.first?.onchainAcceptanceVerified, true)
        try PaykitSubscriptionStateStore().restoreBackup(decoded.subscriptions)
        try await PaykitPaymentProofService.shared.restoreBackup(decoded.pendingProofs)
        try Keychain.delete(key: .paykitAcceptedPaymentRequests)
        try Keychain.delete(key: .paykitUsdtPayments)
        try acceptanceStore.restoreBackup(XCTUnwrap(decoded.acceptedOneTimeRequests))
        XCTAssertEqual(try acceptanceStore.load(identity: identity), [acceptedId])

        XCTAssertEqual(try PaykitSubscriptionStateStore().load(identity: identity), subscriptions)
        let loaded = try await PaykitPaymentProofStore().load()
        XCTAssertEqual(loaded, [proof])
        let restoredBackup = try await PaykitPaymentProofService.shared.backupSnapshot()
        XCTAssertEqual(restoredBackup.first?.onchainWalletId, "trezor:android")
    }

    func testUsdtBackupPreservesSharedWireFormat() throws {
        let fixture = """
        {
          "attempts": [
            {
              "quoteId": "operation",
              "wallet": "wallet",
              "identity": "alice",
              "contact": "bob",
              "requestId": {
                "paymentRequestId": "request",
                "counterparty": "bob",
                "billingPeriodStartsAt": "2026-10-01T00:00:00.125Z"
              },
              "binding": {
                "payer": "alice",
                "payee": "bob",
                "paymentAppId": "bitkit",
                "paymentRequestId": "request",
                "paymentReference": "invoice",
                "paymentEndpointIdentifier": "usdt-arbitrum-address",
                "periodStartsAt": "2026-10-01T00:00:00.125Z",
                "periodEndsAt": "2026-11-01T00:00:00.125Z",
                "conversionQuoteId": "quote"
              },
              "billingPeriod": {
                "startsAt": "2026-10-01T00:00:00.125Z",
                "endsAt": "2026-11-01T00:00:00.125Z"
              },
              "proof": null,
              "proofQueued": false,
              "paymentStarted": true
            }
          ],
          "receipts": [
            {
              "wallet": "wallet",
              "identity": "alice",
              "requestId": {
                "paymentRequestId": "request",
                "counterparty": "bob",
                "billingPeriodStartsAt": "2026-10-01T00:00:00.125Z"
              },
              "paymentId": "42161:transaction:2",
              "proofEventId": "proof",
              "verified": true,
              "transferId": "transfer",
              "amountAtomic": 50000,
              "receivedAtMillis": 1790812801000,
              "underpaid": false,
              "afterExpiry": false
            }
          ]
        }
        """
        let backup = try JSONDecoder().decode(PaykitUsdtStateBackup.self, from: Data(fixture.utf8))
        let attempt = try XCTUnwrap(backup.attempts.first).restored()
        let receipt = try XCTUnwrap(backup.receipts.first).restored()
        XCTAssertTrue(attempt.paymentStarted)
        XCTAssertEqual(attempt.binding?.paymentAppId, "bitkit")
        XCTAssertEqual(attempt.binding?.conversionQuoteId, "quote")
        XCTAssertEqual(attempt.billingPeriod?.sdkValue.startsAt, "2026-10-01T00:00:00.125Z")
        XCTAssertEqual(receipt.amount.atomic, 50000)
        XCTAssertEqual(receipt.requestId, attempt.requestId)
        let encoded = try JSONEncoder().encode(PaykitUsdtStateBackup(attempts: [.init(attempt)], receipts: [.init(receipt)]))
        let restored = try JSONDecoder().decode(PaykitUsdtStateBackup.self, from: encoded)
        XCTAssertEqual(try restored.attempts.first?.restored(), attempt)
        XCTAssertEqual(try restored.receipts.first?.restored(), receipt)
    }

    @MainActor
    func testUsdtRestorePreservesStartedPaymentsWhenSnapshotsOverlap() throws {
        let service = PaykitUsdtPaymentService()
        let started = PaykitUsdtPaymentService.Attempt(quoteId: "operation", wallet: "wallet", identity: "alice", contact: "bob",
                                                       requestId: nil, binding: nil, billingPeriod: nil, proofQueued: true,
                                                       paymentStarted: true)
        var unstarted = started
        unstarted.paymentStarted = false
        let older = PaykitUsdtStateBackup(attempts: [.init(unstarted)], receipts: [])
        try service.restoreBackup(older)
        try service.restoreBackup(PaykitUsdtStateBackup(attempts: [.init(started)], receipts: []))
        try service.restoreBackup(older)
        let restored = try XCTUnwrap(service.backupSnapshot().attempts.first).restored()
        XCTAssertTrue(restored.paymentStarted)
        XCTAssertFalse(restored.proofQueued)
    }

    func testUnreadablePaymentStateIsPreserved() async throws {
        let data = Data("not-json".utf8)
        try Keychain.upsert(key: .paykitSubscriptionState, data: data)
        try Keychain.upsert(key: .paykitPendingPaymentProofs, data: data)

        XCTAssertThrowsError(try PaykitSubscriptionStateStore().backupSnapshot())
        XCTAssertThrowsError(try PaykitSubscriptionStateStore().save(PaykitSubscriptionState(), identity: identity))
        do {
            _ = try await PaykitPaymentProofStore().load()
            XCTFail("Unreadable proof state must fail")
        } catch is Swift.DecodingError {}
        XCTAssertEqual(try Keychain.load(key: .paykitSubscriptionState), data)
        XCTAssertEqual(try Keychain.load(key: .paykitPendingPaymentProofs), data)
    }

    func testAttemptChangesNotifyWalletBackup() throws {
        var changes = 0
        let observation = OnchainSendAttemptStore.walletBackupDataChangedPublisher.sink { changes += 1 }
        defer { observation.cancel() }
        try OnchainSendAttemptStore().save([])
        XCTAssertEqual(changes, 1)
    }

    func testSubscriptionChangesNotifyBackup() throws {
        var changes = 0
        let observation = PaykitSubscriptionStateStore.walletBackupDataChangedPublisher.sink { changes += 1 }
        defer { observation.cancel() }
        try PaykitSubscriptionStateStore().save(PaykitSubscriptionState(), identity: identity)
        XCTAssertEqual(changes, 1)
    }

    func testPendingWalletRestoreMarkerIsDetectedBeforeAndAfterPayloadDownload() throws {
        try Keychain.delete(key: .paykitPendingBackupRestore)
        XCTAssertFalse(BackupService.shared.hasPendingWalletRestore())

        try Keychain.upsert(key: .paykitPendingBackupRestore, data: Data())
        XCTAssertTrue(BackupService.shared.hasPendingWalletRestore())

        try Keychain.upsert(key: .paykitPendingBackupRestore, data: Data("wallet-backup".utf8))
        XCTAssertTrue(BackupService.shared.hasPendingWalletRestore())
    }

    func testWalletBackupRestoreGateBlocksStartUntilRestoreCompletion() {
        XCTAssertTrue(WalletBackupRestoreGate.blocksWalletStart(
            isRestoreRunning: true,
            hasPendingRestore: false,
            isRestoreCompletionStart: false
        ))
        XCTAssertFalse(WalletBackupRestoreGate.blocksWalletStart(
            isRestoreRunning: true,
            hasPendingRestore: false,
            isRestoreCompletionStart: true
        ))
        XCTAssertTrue(WalletBackupRestoreGate.blocksWalletStart(
            isRestoreRunning: true,
            hasPendingRestore: true,
            isRestoreCompletionStart: true
        ))
    }

    func testWalletBackupRestoreGateRetainsFailuresAndReplaysPayloadUntilCompletion() async throws {
        var storedPayload: Data?
        let gate = WalletBackupRestoreGate(
            load: { storedPayload },
            store: { storedPayload = $0 },
            clear: { storedPayload = nil }
        )
        let walletBackup = Data("wallet-backup".utf8)
        var downloadCount = 0

        do {
            _ = try await gate.performRestore { retainedPayload in
                XCTAssertNil(retainedPayload)
                downloadCount += 1
                throw PaykitPaymentStateBackupTestError.restoreFailed
            }
            XCTFail("Expected the download failure to preserve the placeholder")
        } catch PaykitPaymentStateBackupTestError.restoreFailed {}
        XCTAssertEqual(storedPayload, Data())
        XCTAssertThrowsError(try gate.requireReplacementBackupAllowed())

        do {
            _ = try await gate.performRestore { retainedPayload in
                XCTAssertNil(retainedPayload)
                downloadCount += 1
                try gate.retain(walletBackup)
                throw PaykitPaymentStateBackupTestError.restoreFailed
            }
            XCTFail("Expected the apply failure to preserve the downloaded payload")
        } catch PaykitPaymentStateBackupTestError.restoreFailed {}
        XCTAssertEqual(storedPayload, walletBackup)
        XCTAssertThrowsError(try gate.requireReplacementBackupAllowed())

        let didRestore = try await gate.performRestore { retainedPayload in
            XCTAssertEqual(retainedPayload, walletBackup)
            XCTAssertEqual(downloadCount, 2)
            return true
        }

        XCTAssertTrue(didRestore)
        XCTAssertNil(storedPayload)
        XCTAssertNoThrow(try gate.requireReplacementBackupAllowed())
    }

    func testWalletBackupRestoreGateClearsPlaceholderWhenNoWalletPayloadExists() async throws {
        var storedPayload: Data?
        let gate = WalletBackupRestoreGate(
            load: { storedPayload },
            store: { storedPayload = $0 },
            clear: { storedPayload = nil }
        )

        let didRestore = try await gate.performRestore { retainedPayload in
            XCTAssertNil(retainedPayload)
            XCTAssertEqual(storedPayload, Data())
            return false
        }

        XCTAssertFalse(didRestore)
        XCTAssertNil(storedPayload)
        XCTAssertNoThrow(try gate.requireReplacementBackupAllowed())
    }

    func testOnlyWalletRestoreFailuresAreFatal() {
        XCTAssertTrue(BackupRestoreFailurePolicy.isFatal(.wallet))

        for category in BackupCategory.allCases where category != .wallet {
            XCTAssertFalse(BackupRestoreFailurePolicy.isFatal(category))
        }
    }

    func testAndroidPaymentStatePreservesPreciseAcceptanceBillingBoundaries() throws {
        let data = Data("""
        {
          "subscriptions": {
            "\(identity)": {
              "acceptances": [
                {"id":{"paymentRequestId":"millisecond","counterparty":"bob"},"acceptedAt":"2026-09-24T10:00:00.123Z"},
                {"id":{"paymentRequestId":"nanosecond","counterparty":"bob"},"acceptedAt":"2026-09-24T10:00:00.123456789Z"}
              ],
              "presentedProposalIds": []
            }
          },
          "pendingProofs": [{
            "identity": "\(identity)",
            "requestId": {"paymentRequestId":"request","counterparty":"bob","billingPeriodStartsAt":"2026-09-24T10:00:00.100Z"},
            "paymentAppId": "bitkit",
            "paymentEndpointIdentifier": "bitcoin-onchain",
            "kind": "bitcoin-onchain-txid",
            "paymentStarted": true,
            "billingPeriod": {"startsAt":"2026-09-24T10:00:00.100Z","endsAt":"2026-09-25T10:00:00.100Z"},
            "onchainWalletId": "trezor:android",
            "onchainMatchingTransactionIdsBeforeAttempt": []
          }]
        }
        """.utf8)
        let backup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: data)
        let store = PaykitSubscriptionStateStore()
        try store.restoreBackup(backup.subscriptions)
        let persistedBackup = try PaykitPaymentStateBackup(
            subscriptions: store.backupSnapshot(),
            pendingProofs: backup.pendingProofs
        )
        let roundTrippedBackup = try JSONDecoder().decode(
            PaykitPaymentStateBackup.self,
            from: JSONEncoder().encode(persistedBackup)
        )
        try store.restoreBackup(roundTrippedBackup.subscriptions)

        let restoredAcceptedAt = try store.load(identity: identity).acceptedAt
        let millisecondId = PaykitSubscription.ID(
            paymentRequestId: "millisecond",
            counterparty: "bob"
        )
        let nanosecondId = PaykitSubscription.ID(
            paymentRequestId: "nanosecond",
            counterparty: "bob"
        )
        XCTAssertEqual(restoredAcceptedAt[millisecondId]?.timestamp, "2026-09-24T10:00:00.123Z")
        XCTAssertEqual(restoredAcceptedAt[nanosecondId]?.timestamp, "2026-09-24T10:00:00.123456789Z")

        let through = try XCTUnwrap(PaykitPreciseInstant(timestamp: "2026-09-24T10:00:01Z")?.date)
        let boundaryCases: [(PaykitSubscription.ID, String, Int)] = [
            (millisecondId, "122999950", 1),
            (millisecondId, "123", 1),
            (millisecondId, "123000050", 2),
            (nanosecondId, "123456788", 1),
            (nanosecondId, "123456789", 1),
            (nanosecondId, "123456790", 2),
        ]
        for (id, boundaryFraction, expectedCount) in boundaryCases {
            let recurrence = try XCTUnwrap(PaykitSubscriptionRecurrence(PaymentRequestRecurrence(
                every: 1,
                unit: "day",
                startsAt: "2026-09-23T10:00:00.\(boundaryFraction)Z",
                anchor: "2026-09-23T10:00:00.\(boundaryFraction)Z",
                endsAt: nil
            )))
            let acceptedAt = try XCTUnwrap(restoredAcceptedAt[id])
            XCTAssertEqual(
                recurrence.periods(through: through, acceptedAt: acceptedAt).count,
                expectedCount,
                "Unexpected billing eligibility for \(id.paymentRequestId) at .\(boundaryFraction)Z"
            )
        }

        let proof = try XCTUnwrap(backup.pendingProofs.first).restored()
        XCTAssertTrue(proof.paymentStarted)
        XCTAssertNil(proof.onchainAcceptanceVerified)
        XCTAssertEqual(proof.requestId.billingPeriodStartsAt, proof.billingPeriod?.startsAt)
        XCTAssertEqual(proof.onchainWalletId, "trezor:android")
        XCTAssertEqual(PaykitPaymentStateBackup.Proof(proof).onchainWalletId, "trezor:android")

        let millisecondData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: ".123Z", with: ".100Z").utf8)
        let millisecondBackup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: millisecondData)
        XCTAssertEqual(try millisecondBackup.subscriptions[identity]?.restored().acceptedAt.count, 2)

        let malformedData = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "2026-09-24T10:00:00.123Z", with: "not-a-timestamp").utf8)
        let malformedBackup = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: malformedData)
        XCTAssertThrowsError(try malformedBackup.subscriptions[identity]?.restored())
    }

    func testLegacyStoredAcceptanceDateDecodesAndMigratesToPreciseTimestamp() throws {
        let id = PaykitSubscription.ID(
            paymentRequestId: "subscription",
            counterparty: identity
        )
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T10:00:00Z"))
        let legacyState = LegacyState(subscriptionsByIdentity: [
            identity: LegacySubscriptionState(
                acceptedAt: [id: acceptedAt],
                presentedProposalIds: [id],
                dismissedPaymentIds: []
            ),
        ])
        try Keychain.upsert(key: .paykitSubscriptionState, data: JSONEncoder().encode(legacyState))

        let store = PaykitSubscriptionStateStore()
        let restored = try store.load(identity: identity)
        XCTAssertEqual(restored.acceptedAt[id]?.timestamp, "2026-09-24T10:00:00Z")

        try store.save(restored, identity: identity)
        let migratedData = try XCTUnwrap(Keychain.load(key: .paykitSubscriptionState))
        XCTAssertTrue(String(decoding: migratedData, as: UTF8.self).contains("2026-09-24T10:00:00Z"))
    }
}

private actor BackupWriteEvents {
    private(set) var values: [Int] = []
    func append(_ value: Int) {
        values.append(value)
    }
}
