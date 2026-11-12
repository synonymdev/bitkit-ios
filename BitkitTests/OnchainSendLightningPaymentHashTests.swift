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
            let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
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
        let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
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
        let backedUpService = OnchainSendAttemptService(store: backedUpStore, lightningHolds: MemoryLightningHoldStore())
        let original = try await dispatchedOriginal(backedUpService, store: backedUpStore, sender: sender, lightningPaymentHash: paymentHash)
        let snapshot = try await backedUpService.backupSnapshot(wallet: wallet, proofs: [])
        let wire = try JSONDecoder().decode(
            PaykitPaymentStateBackup.ActiveOnchainAttempt.self, from: JSONEncoder().encode(XCTUnwrap(snapshot))
        )
        let restored = try wire.restored(wallet: wallet, proofs: []).0
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.lightningPaymentHash, paymentHash)
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
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
            let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
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
        let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
        let none = await service.lightningHold(paymentHash: paymentHash) == .held
        XCTAssertFalse(none, "No on-chain send holds anything")

        _ = try await dispatchedOriginal(service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash)
        let held = await service.lightningHold(paymentHash: paymentHash.uppercased()) == .held
        let other = await service.lightningHold(paymentHash: String(repeating: "ef", count: 32)) == .held
        XCTAssertTrue(held)
        XCTAssertFalse(other)

        // An accepted send keeps holding it, as its transaction pays the invoice once it confirms
        var accepted = try XCTUnwrap(store.snapshot().first)
        accepted.status = .accepted
        accepted.localFollowupComplete = true
        try store.save([accepted])
        let heldOnceAccepted = await service.lightningHold(paymentHash: paymentHash) == .held
        XCTAssertTrue(heldOnceAccepted)

        store.failLoad = true
        let whileUnreadable = await service.lightningHold(paymentHash: String(repeating: "ef", count: 32))
        XCTAssertEqual(whileUnreadable, .unreadable, "An attempt store that cannot be read shows no invoice free")
    }

    /// Both directions: an unresolved on-chain send of a unified code's address refuses its invoice over Lightning, at the scan
    /// and at Confirm, and a pending Lightning payment of the invoice refuses its address
    func testAUnifiedCodeIsNeverPaidBothWays() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
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
                lightningHold: { await service.lightningHold(paymentHash: $0) }
            )
        )

        let lightningRefusal = await SendConfirmationView.lightningDispatchRefusal(
            walletType: .lightning, paymentHash: paymentHash, cameWithAddress: true, lightningHold: app.lightningHold
        )
        let onchainUnaffected = await SendConfirmationView.lightningDispatchRefusal(
            walletType: .onchain, paymentHash: paymentHash, cameWithAddress: true, lightningHold: app.lightningHold
        )
        XCTAssertNotNil(lightningRefusal)
        XCTAssertNil(onchainUnaffected)

        let otherInvoice = await SendConfirmationView.lightningDispatchRefusal(
            walletType: .lightning, paymentHash: String(repeating: "ef", count: 32), cameWithAddress: true,
            lightningHold: app.lightningHold
        )
        XCTAssertNil(otherInvoice)

        let pending = makeApp(listPayments: { [AppViewModelTests.outboundBolt11Payment(paymentHash: self.paymentHash, status: .pending)] })
        let addressRefusal = await SendConfirmationView.onchainDispatchRefusal(
            walletType: .onchain, lightningPaymentHash: paymentHash, lightningPaymentStatus: pending.lightningPaymentStatus
        )
        XCTAssertEqual(addressRefusal?.status, .pending)
    }

    func testARejectedAttemptStillHoldsItsInvoice() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
        let original = try await dispatchedOriginal(service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash)
        XCTAssertEqual(original.status, .rejected)

        let hold = await service.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(hold, .held, "A rejected broadcast may still have propagated")
    }

    func testTheInvoiceStaysHeldAfterItsSendIsReplacedUntilItExpired() async throws {
        let store = MemoryAttemptStore()
        let holds = MemoryLightningHoldStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let service = OnchainSendAttemptService(store: store, lightningHolds: holds, now: { clock.now })
        let sender = PreparedAttemptNodeMock()
        _ = try await dispatchedOriginal(
            service, store: store, sender: sender, lightningPaymentHash: paymentHash, lightningInvoiceExpiresAt: 1_000_600
        )
        var resolved = try XCTUnwrap(store.snapshot().first)
        resolved.status = .accepted
        resolved.localFollowupComplete = true
        try store.save([resolved])
        // A restarted app reads the resolved attempt
        let restarted = OnchainSendAttemptService(store: store, lightningHolds: holds, now: { clock.now })

        // A later on-chain send replaces the attempt
        sender.txid = String(repeating: "ef", count: 32)
        sender.result = .accepted(txid: sender.txid)
        _ = try await restarted.send(
            using: sender, address: "bcrt1qother", amountSats: sender.amount, satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false
        )
        XCTAssertNil(store.snapshot().first?.lightningPaymentHash)
        XCTAssertEqual(holds.snapshot(), [HeldLightningInvoice(paymentHash: paymentHash, expiresAt: 1_000_600)])
        let afterReplacement = await restarted.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(afterReplacement, .held)

        // Expired, but not yet past the margin
        clock.now = Date(timeIntervalSince1970: 1_000_600 + 3599)
        let withinMargin = await restarted.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(withinMargin, .held)

        clock.now = Date(timeIntervalSince1970: 1_000_600 + 3601)
        let pastMargin = await restarted.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(pastMargin, .none)
    }

    func testAnAttemptThatNeverWentOutHoldsNothingOnceItIsCleared() async throws {
        let store = MemoryAttemptStore()
        let holds = MemoryLightningHoldStore()
        let service = OnchainSendAttemptService(store: store, lightningHolds: holds)
        let sender = PreparedAttemptNodeMock()
        sender.onPrepare = { throw URLError(.notConnectedToInternet) }

        do {
            _ = try await service.send(
                using: sender, address: "bcrt1qrecipient", amountSats: sender.amount, satsPerVbyte: 2, utxosToSpend: nil,
                isMaxAmount: false, lightningPaymentHash: paymentHash
            )
            XCTFail("The send prepared nothing")
        } catch {}

        XCTAssertTrue(store.snapshot().isEmpty)
        let hold = await service.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(hold, .none)
    }

    func testPaidInvoicesSurviveABackupRestore() async throws {
        let holds = MemoryLightningHoldStore()
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        try holds.save([
            HeldLightningInvoice(paymentHash: paymentHash, expiresAt: 2_000_000),
            HeldLightningInvoice(paymentHash: String(repeating: "ef", count: 32), expiresAt: 10),
        ])
        let service = OnchainSendAttemptService(store: MemoryAttemptStore(), lightningHolds: holds, now: { clock.now })
        let backedUp = await service.lightningHoldsBackup()
        let backup = try XCTUnwrap(backedUp).map(PaykitPaymentStateBackup.OnchainPaidInvoice.init)
        let wire = try JSONDecoder().decode([PaykitPaymentStateBackup.OnchainPaidInvoice].self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(wire.count, 1, "An expired invoice is not backed up")

        let restoredHolds = MemoryLightningHoldStore()
        let restoredService = OnchainSendAttemptService(store: MemoryAttemptStore(), lightningHolds: restoredHolds, now: { clock.now })
        let restored = try wire.map { try $0.restored() }
        await restoredService.restoreLightningHolds(restored)

        let held = await restoredService.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(held, .held)

        for malformed in [#"{"paymentHash":"not-a-hash","expiresAt":"1"}"#, #"{"paymentHash":"\#(paymentHash)","expiresAt":"+1"}"#] {
            let record = try JSONDecoder().decode(PaykitPaymentStateBackup.OnchainPaidInvoice.self, from: Data(malformed.utf8))
            XCTAssertThrowsError(try record.restored(), malformed)
        }
    }

    /// The record is shared with Android: `onchainPaidInvoices`, each `{"paymentHash", "expiresAt"}` with the expiry in seconds
    /// since 1970 as a decimal string, and the key left out when there are none
    func testPaidInvoicesUseTheSharedBackupSchema() throws {
        let android = #"{"subscriptions":{},"pendingProofs":[],"onchainPaidInvoices":[{"paymentHash":"\#(paymentHash)","expiresAt":"1700000000"}]}"#
        let decoded = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: Data(android.utf8))
        let restored = try XCTUnwrap(decoded.onchainPaidInvoices).map { try $0.restored() }
        XCTAssertEqual(restored, [HeldLightningInvoice(paymentHash: paymentHash, expiresAt: 1_700_000_000)])

        var state = PaykitPaymentStateBackup(subscriptions: [:], pendingProofs: [])
        state.onchainPaidInvoices = restored.map(PaykitPaymentStateBackup.OnchainPaidInvoice.init)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let invoices = try XCTUnwrap(encoded["onchainPaidInvoices"] as? [[String: Any]])
        XCTAssertEqual(invoices.first?["paymentHash"] as? String, paymentHash)
        XCTAssertEqual(invoices.first?["expiresAt"] as? String, "1700000000")
        XCTAssertEqual(invoices.first?.count, 2)

        let empty = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(PaykitPaymentStateBackup(
                subscriptions: [:],
                pendingProofs: []
            ))) as? [String: Any]
        )
        XCTAssertNil(empty["onchainPaidInvoices"])
    }

    func testAnUnreadablePaidInvoiceListNeverBlocksASendABackupOrARestore() async throws {
        let store = MemoryAttemptStore()
        let holds = MemoryLightningHoldStore()
        holds.failLoad = true
        let service = OnchainSendAttemptService(store: store, lightningHolds: holds)

        let original = try await dispatchedOriginal(
            service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash, lightningInvoiceExpiresAt: 4_000_000_000
        )
        XCTAssertEqual(store.snapshot(), [original], "The outcome is saved")
        let hold = await service.lightningHold(paymentHash: String(repeating: "ef", count: 32))
        XCTAssertEqual(hold, .unreadable, "The Lightning check still fails closed")
        let backup = await service.lightningHoldsBackup()
        XCTAssertNil(backup, "The backup leaves the list out")

        await service.restoreLightningHolds([HeldLightningInvoice(paymentHash: paymentHash, expiresAt: 4_000_000_000)])
        let restoredStore = MemoryAttemptStore()
        let restoring = OnchainSendAttemptService(store: restoredStore, lightningHolds: holds)
        try await restoring.restoreBackup(original)
        XCTAssertEqual(restoredStore.snapshot().first?.id, original.id, "The attempt is restored")
    }

    func testAMalformedPaidInvoiceIsDroppedFromARestore() throws {
        let json = #"{"subscriptions":{},"pendingProofs":[],"onchainPaidInvoices":[{"paymentHash":"\#(paymentHash)","expiresAt":"1700000000"},{"paymentHash":"not-a-hash","expiresAt":"1"}]}"#
        let state = try JSONDecoder().decode(PaykitPaymentStateBackup.self, from: Data(json.utf8))

        XCTAssertEqual(state.restoredOnchainPaidInvoices(), [HeldLightningInvoice(paymentHash: paymentHash, expiresAt: 1_700_000_000)])
    }

    func testAnAcceptedSendHoldsItsInvoiceAsPaid() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store, lightningHolds: MemoryLightningHoldStore())
        let sender = PreparedAttemptNodeMock()
        sender.result = .accepted(txid: sender.txid)
        _ = try await service.send(
            using: sender, address: "bcrt1qrecipient", amountSats: sender.amount, satsPerVbyte: 2, utxosToSpend: nil,
            isMaxAmount: false, lightningPaymentHash: paymentHash
        )

        let hold = await service.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(hold, .paid)
        let refusal = await LightningPaymentHeldRefusal.check(paymentHash: paymentHash, cameWithAddress: true, lightningHold: { _ in hold })
        XCTAssertEqual(refusal?.isSettled, true)
    }

    func testOnlyADispatchedSendWithAKnownInvoiceExpiryIsRemembered() async throws {
        let store = MemoryAttemptStore()
        let holds = MemoryLightningHoldStore()
        let service = OnchainSendAttemptService(store: store, lightningHolds: holds)
        _ = try await dispatchedOriginal(service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash)

        XCTAssertTrue(holds.snapshot().isEmpty, "An invoice of unknown expiry is held only by its attempt")
        let heldByAttempt = await service.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(heldByAttempt, .held)
    }

    func testARestoreOverAResolvedAttemptKeepsItsInvoiceHeld() async throws {
        let store = MemoryAttemptStore()
        let holds = MemoryLightningHoldStore()
        let service = OnchainSendAttemptService(store: store, lightningHolds: holds)
        _ = try await dispatchedOriginal(
            service, store: store, sender: PreparedAttemptNodeMock(), lightningPaymentHash: paymentHash, lightningInvoiceExpiresAt: 4_000_000_000
        )
        var resolved = try XCTUnwrap(store.snapshot().first)
        resolved.status = .accepted
        resolved.localFollowupComplete = true
        try store.save([resolved])
        let restarted = OnchainSendAttemptService(store: store, lightningHolds: holds)

        try await restarted.restoreBackup(nil)

        XCTAssertTrue(store.snapshot().isEmpty)
        let hold = await restarted.lightningHold(paymentHash: paymentHash)
        XCTAssertEqual(hold, .held)
    }

    func testUnreadableRecordsHoldOnlyAnInvoiceThatCameWithAnAddress() async {
        func refusal(cameWithAddress: Bool) async -> LightningPaymentHeldRefusal.Reason? {
            await LightningPaymentHeldRefusal.check(
                paymentHash: paymentHash, cameWithAddress: cameWithAddress, lightningHold: { _ in .unreadable }
            )?.reason
        }
        let unified = await refusal(cameWithAddress: true)
        let plainInvoice = await refusal(cameWithAddress: false)
        XCTAssertEqual(unified, .unreadableRecords)
        XCTAssertNil(plainInvoice, "A plain invoice, Lightning-only contact or LNURL pays")

        let held = await LightningPaymentHeldRefusal.check(paymentHash: paymentHash, cameWithAddress: false, lightningHold: { _ in .held })
        XCTAssertEqual(held?.reason, .onchainSend, "A held invoice is refused however it came")
        XCTAssertEqual(LightningPaymentHeldRefusal(reason: .unreadableRecords).description, t("wallet__send_lightning_onchain_unreadable"))
    }

    func testTheRefusalOfAHeldInvoiceSaysWhy() {
        let refusal = LightningPaymentHeldRefusal(reason: .onchainSend)
        XCTAssertEqual(refusal.title, t("common__error"))
        XCTAssertEqual(refusal.description, t("wallet__send_lightning_onchain_pending"))
        XCTAssertEqual(sendFailureMessage(for: refusal), t("wallet__send_lightning_onchain_pending"))
    }

    private func dispatchedOriginal(
        _ service: OnchainSendAttemptService, store: MemoryAttemptStore, sender: PreparedAttemptNodeMock,
        lightningPaymentHash: String?, lightningInvoiceExpiresAt: UInt64? = nil
    ) async throws -> OnchainSendAttempt {
        sender.result = .rejected(txid: sender.txid, reason: "min relay fee not met")
        _ = try await service.send(
            using: sender, address: "bcrt1qrecipient", amountSats: sender.amount, satsPerVbyte: 2, utxosToSpend: nil,
            isMaxAmount: false, lightningPaymentHash: lightningPaymentHash, lightningInvoiceExpiresAt: lightningInvoiceExpiresAt
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

final class MemoryLightningHoldStore: OnchainLightningHoldStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var holds: [HeldLightningInvoice] = []
    var failLoad = false

    func load() throws -> [HeldLightningInvoice] {
        lock.lock()
        defer { lock.unlock() }
        if failLoad {
            throw UnreadableHolds()
        }
        return holds
    }

    func save(_ holds: [HeldLightningInvoice]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.holds = holds
    }

    func snapshot() -> [HeldLightningInvoice] {
        lock.lock()
        defer { lock.unlock() }
        return holds
    }
}

private struct UnreadableHolds: Error {}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }
}
