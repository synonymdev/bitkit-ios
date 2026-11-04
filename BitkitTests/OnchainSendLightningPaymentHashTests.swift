@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

/// An on-chain send of an address that came with a Lightning invoice keeps the invoice's hash, so that every re-send checks the
/// invoice's payment again, also after a restore.
@MainActor
final class OnchainSendLightningPaymentHashTests: XCTestCase {
    private let paymentHash = String(repeating: "cd", count: 32)

    func testARetryOfAnAddressThatCameWithAnInvoiceGoesOutOnlyOnceItsLightningPaymentFailed() async throws {
        let cases: [(payments: [LDKNode.PaymentDetails]?, refusal: LightningPaymentStatus?)] = [
            ([AppViewModelTests.outboundBolt11Payment(paymentHash: paymentHash, status: .pending)], .pending),
            ([AppViewModelTests.outboundBolt11Payment(paymentHash: paymentHash, status: .succeeded)], .succeeded),
            (nil, .unknown),
            ([AppViewModelTests.outboundBolt11Payment(paymentHash: paymentHash, status: .failed)], nil),
        ]
        for (payments, refusal) in cases {
            let label = String(describing: refusal)
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            let original = try await dispatchedOriginal(service, store: store, sender: sender, lightningPaymentHash: paymentHash)
            XCTAssertEqual(original.lightningPaymentHash, paymentHash, label)
            let app = makeApp(listPayments: { payments })
            sender.txid = String(repeating: "ef", count: 32)
            sender.result = .accepted(txid: sender.txid)

            do {
                let result = try await service.retrySamePayment(using: sender, context: pendingContext(original), satsPerVbyte: 2) { attempt, _ in
                    try await SendPendingScreen.checkLightningPaymentBeforeRetry(attempt, lightningPaymentStatus: app.lightningPaymentStatus)
                }
                XCTAssertNil(refusal, label)
                XCTAssertEqual(result, .accepted(txid: sender.txid), label)
                XCTAssertEqual(sender.broadcasts, 2, label)
            } catch let error as OnchainPaymentRefusal {
                XCTAssertEqual(error.status, refusal, label)
                XCTAssertEqual(sender.broadcasts, 1, label)
                XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateTxids, original.recoveryContext?.candidateTxids, label)
            }
        }
    }

    func testAnAttemptSavedBeforeItCarriedAnInvoiceHashCarriesNone() throws {
        let attempt = OnchainSendAttempt(
            id: UUID(), walletId: "node-0", requestId: nil, orderId: nil, address: "bcrt1qrecipient", amountSats: 1000,
            isMaxAmount: false, status: .rejected, txid: String(repeating: "ab", count: 32), lightningPaymentHash: paymentHash
        )
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        XCTAssertEqual(try JSONDecoder().decode(OnchainSendAttempt.self, from: JSONEncoder().encode(attempt)), attempt)

        saved.removeValue(forKey: "lightningPaymentHash")
        let older = try JSONDecoder().decode(OnchainSendAttempt.self, from: JSONSerialization.data(withJSONObject: saved))

        XCTAssertNil(older.lightningPaymentHash)
        var withoutHash = attempt
        withoutHash.lightningPaymentHash = nil
        XCTAssertEqual(older, withoutHash)
    }

    func testABackupReplayMustCarryTheLocalInvoiceHash() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let original = try await dispatchedOriginal(
            service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash
        )

        try await service.restoreBackup(original)
        XCTAssertEqual(store.snapshot(), [original])

        for hash in [nil, String(repeating: "ef", count: 32)] {
            var backedUp = original
            backedUp.lightningPaymentHash = hash
            do {
                try await service.restoreBackup(backedUp)
                XCTFail("A replay without the local invoice hash was taken as the same attempt")
            } catch OnchainSendAttemptError.unresolved {}
            XCTAssertEqual(store.snapshot(), [original])
        }
    }

    func testARestoredAttemptsRetryStillChecksTheInvoiceItsAddressCameWith() async throws {
        let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
            kind: "software", network: Env.networkName, binding: String(repeating: "12", count: 32), sourceIndex: "0"
        )
        let sender = PreparedAttemptNodeMock()
        let backedUpStore = MemoryAttemptStore()
        let backedUpService = OnchainSendAttemptService(store: backedUpStore)
        let original = try await dispatchedOriginal(backedUpService, store: backedUpStore, sender: sender, lightningPaymentHash: paymentHash)
        let snapshot = try await backedUpService.backupSnapshot(wallet: wallet, proofs: [])
        let wire = try JSONDecoder().decode(
            PaykitPaymentStateBackup.ActiveOnchainAttempt.self, from: JSONEncoder().encode(XCTUnwrap(snapshot))
        )
        let restored = try wire.restored(wallet: wallet, proofs: []).0
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.lightningPaymentHash, paymentHash)
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        try await service.restoreBackup(restored)
        let app = makeApp(listPayments: { [AppViewModelTests.outboundBolt11Payment(paymentHash: self.paymentHash, status: .pending)] })
        sender.txid = String(repeating: "ef", count: 32)
        sender.result = .accepted(txid: sender.txid)

        do {
            _ = try await service.retrySamePayment(using: sender, context: pendingContext(restored), satsPerVbyte: 2) { attempt, _ in
                try await SendPendingScreen.checkLightningPaymentBeforeRetry(attempt, lightningPaymentStatus: app.lightningPaymentStatus)
            }
            XCTFail("Retry re-sent a restored address while its invoice's Lightning payment was pending")
        } catch let refusal as OnchainPaymentRefusal {
            XCTAssertEqual(refusal.status, .pending)
        }
        XCTAssertEqual(sender.broadcasts, 1)
        XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateTxids, restored.recoveryContext?.candidateTxids)
    }

    func testTheBackupKeepsTheInvoiceHashAndRefusesAMalformedOne() async throws {
        let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
            kind: "software", network: Env.networkName, binding: String(repeating: "12", count: 32), sourceIndex: "0"
        )
        for hash in [paymentHash, nil] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            _ = try await dispatchedOriginal(service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: hash)
            let backup = try await service.backupSnapshot(wallet: wallet, proofs: [])
            let snapshot = try XCTUnwrap(backup)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            XCTAssertEqual(json["lightningPaymentHash"] as? String, hash)
            XCTAssertEqual(json.keys.contains("lightningPaymentHash"), hash != nil, "An attempt without a hash writes no key")

            if hash != nil {
                json["lightningPaymentHash"] = "not-a-hash"
                let malformed = try JSONDecoder().decode(
                    PaykitPaymentStateBackup.ActiveOnchainAttempt.self, from: JSONSerialization.data(withJSONObject: json)
                )
                XCTAssertThrowsError(try malformed.restored(wallet: wallet, proofs: []))
            }
        }
    }

    func testAnOnchainSendOfAnInvoicesAddressHoldsThatInvoiceUntilItIsReplaced() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let none = await service.holdsLightningPayment(paymentHash: paymentHash)
        XCTAssertFalse(none, "No on-chain send holds anything")

        _ = try await dispatchedOriginal(service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash)
        let held = await service.holdsLightningPayment(paymentHash: paymentHash.uppercased())
        let other = await service.holdsLightningPayment(paymentHash: String(repeating: "ef", count: 32))
        XCTAssertTrue(held)
        XCTAssertFalse(other)

        // An accepted send keeps holding it, as its transaction pays the invoice once it confirms
        var accepted = try XCTUnwrap(store.snapshot().first)
        accepted.status = .accepted
        accepted.localFollowupComplete = true
        try store.save([accepted])
        let heldOnceAccepted = await service.holdsLightningPayment(paymentHash: paymentHash)
        XCTAssertTrue(heldOnceAccepted)

        store.failLoad = true
        let heldWhileUnreadable = await service.holdsLightningPayment(paymentHash: String(repeating: "ef", count: 32))
        XCTAssertTrue(heldWhileUnreadable, "An attempt store that cannot be read holds every invoice")
    }

    /// Both directions: an unresolved on-chain send of a unified code's address refuses its invoice over Lightning, at the scan
    /// and at Confirm, and a pending Lightning payment of the invoice refuses its address
    func testAUnifiedCodeIsNeverPaidBothWays() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        _ = try await dispatchedOriginal(service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash)
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true, spendableOnchainBalanceSats: 0, totalLightningBalanceSats: 0,
                        hasChannels: false, hasUsableChannels: false
                    )
                },
                canSendLightning: { _ in false },
                listPayments: { [] },
                isHeldByOnchainSend: { await service.holdsLightningPayment(paymentHash: $0) }
            )
        )

        let lightningRefusal = await SendConfirmationView.lightningDispatchRefusal(
            walletType: .lightning, paymentHash: paymentHash, isHeldByOnchainSend: app.isHeldByOnchainSend
        )
        let onchainUnaffected = await SendConfirmationView.lightningDispatchRefusal(
            walletType: .onchain, paymentHash: paymentHash, isHeldByOnchainSend: app.isHeldByOnchainSend
        )
        XCTAssertNotNil(lightningRefusal)
        XCTAssertNil(onchainUnaffected)

        let otherInvoice = await SendConfirmationView.lightningDispatchRefusal(
            walletType: .lightning, paymentHash: String(repeating: "ef", count: 32), isHeldByOnchainSend: app.isHeldByOnchainSend
        )
        XCTAssertNil(otherInvoice)

        let pending = makeApp(listPayments: { [AppViewModelTests.outboundBolt11Payment(paymentHash: self.paymentHash, status: .pending)] })
        let addressRefusal = await SendConfirmationView.onchainDispatchRefusal(
            walletType: .onchain, lightningPaymentHash: paymentHash, lightningPaymentStatus: pending.lightningPaymentStatus
        )
        XCTAssertEqual(addressRefusal?.status, .pending)
    }

    func testTheRefusalOfAHeldInvoiceSaysWhy() {
        let refusal = LightningPaymentHeldRefusal()
        XCTAssertEqual(refusal.title, t("common__error"))
        XCTAssertEqual(refusal.description, t("wallet__send_lightning_onchain_pending"))
        XCTAssertEqual(sendFailureMessage(for: refusal), t("wallet__send_lightning_onchain_pending"))
    }

    private func dispatchedOriginal(
        _ service: OnchainSendAttemptService, store: MemoryAttemptStore, sender: PreparedAttemptNodeMock,
        lightningPaymentHash: String?
    ) async throws -> OnchainSendAttempt {
        sender.result = .rejected(txid: sender.txid, reason: "min relay fee not met")
        _ = try await service.send(
            using: sender, address: "bcrt1qrecipient", amountSats: sender.amount, satsPerVbyte: 2, utxosToSpend: nil,
            isMaxAmount: false, lightningPaymentHash: lightningPaymentHash
        )
        let original = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(original.status, .rejected)
        XCTAssertTrue(original.canRetrySamePayment)
        return original
    }

    private func pendingContext(_ attempt: OnchainSendAttempt) -> OnchainSendPendingContext {
        OnchainSendPendingContext(attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid)
    }

    private func makeApp(listPayments: @escaping () async -> [LDKNode.PaymentDetails]?) -> AppViewModel {
        AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true, spendableOnchainBalanceSats: 0, totalLightningBalanceSats: 0,
                        hasChannels: false, hasUsableChannels: false
                    )
                },
                canSendLightning: { _ in false },
                listPayments: listPayments
            )
        )
    }
}
