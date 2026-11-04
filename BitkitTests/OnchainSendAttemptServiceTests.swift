@testable import Bitkit
import BitkitCore
import LDKNode
import Paykit
import XCTest

final class OnchainSendAttemptServiceTests: XCTestCase {
    private let walletId = "node-0"
    private let txid = String(repeating: "ab", count: 32)

    func testBlockedNewRequestRoutesToOriginalPayment() async throws {
        let originalShop = PaykitPaymentRequest.ID(paymentRequestId: "original-shop", counterparty: "original-merchant", billingPeriodStartsAt: nil)
        let newShop = PaykitPaymentRequest.ID(paymentRequestId: "new-shop", counterparty: "new-merchant", billingPeriodStartsAt: nil)
        for originalRequest in [nil, originalShop] as [PaykitPaymentRequest.ID?] {
            let store = MemoryAttemptStore()
            let retained = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: originalRequest, orderId: nil,
                                              address: "bcrt1qoriginal", amountSats: 1000, isMaxAmount: false,
                                              status: .unknown, txid: txid)
            try store.save([retained])
            let service = OnchainSendAttemptService(store: store)
            let route = await SendConfirmationView.onchainPendingRoute(requestId: newShop, using: service)
            guard case let .onchainOperationPending(context, requestId) = route else {
                return XCTFail("Blocked new request must display the original payment")
            }
            XCTAssertEqual(context.attemptId, retained.id)
            XCTAssertEqual(context.walletId, retained.walletId)
            XCTAssertEqual(context.txid, retained.txid)
            XCTAssertEqual(requestId, originalRequest)
            XCTAssertEqual(store.snapshot(), [retained])
        }
    }

    @MainActor
    func testBlockedRequestReleasesOnlyItsUnsentReservation() async throws {
        let request = PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "merchant", billingPeriodStartsAt: nil)
        let other = PaykitPaymentRequest.ID(paymentRequestId: "other", counterparty: "merchant", billingPeriodStartsAt: nil)
        let otherPeer = PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "other-merchant", billingPeriodStartsAt: nil)
        let otherPeriod = PaykitPaymentRequest.ID(paymentRequestId: "request", counterparty: "merchant",
                                                  billingPeriodStartsAt: Date(timeIntervalSince1970: 123))
        for previousRequest in [nil, request, other, otherPeer, otherPeriod] as [PaykitPaymentRequest.ID?] {
            let store = MemoryAttemptStore()
            let original = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: previousRequest, orderId: nil,
                                              address: "original", amountSats: 1000, isMaxAmount: false, status: .unknown, txid: txid)
            try store.save([original])
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            do {
                _ = try await service.send(using: node, address: "new", amountSats: 2000, satsPerVbyte: 1,
                                           utxosToSpend: nil, isMaxAmount: false, requestId: request,
                                           beforeBroadcastAttempt: { XCTFail("Blocked request must not reach authorization") })
                XCTFail("An unresolved attempt must still block the send")
            } catch {
                XCTAssertEqual(SendConfirmationView.isUnsentBlockedRequest(request, onchainPaymentStarted: false, error: error),
                               previousRequest != request)
                XCTAssertFalse(SendConfirmationView.isUnsentBlockedRequest(request, onchainPaymentStarted: true, error: error))
                XCTAssertFalse(SendConfirmationView.isUnsentBlockedRequest(nil, onchainPaymentStarted: false, error: error))
                XCTAssertFalse(String(describing: error).contains("merchant"), "Errors must not log the blocker identity")
            }
            XCTAssertEqual(node.calls, 0)
            XCTAssertEqual(store.snapshot(), [original])
            let route = await SendConfirmationView.onchainPendingRoute(requestId: request, using: service)
            guard case let .onchainOperationPending(context, routeRequest) = route else {
                return XCTFail("Keep the original payment recovery route")
            }
            XCTAssertEqual(context.attemptId, original.id)
            XCTAssertEqual(routeRequest, previousRequest)
            store.failLoad = true
            do {
                _ = try await service.send(using: node, address: "new", amountSats: 2000, satsPerVbyte: 1,
                                           utxosToSpend: nil, isMaxAmount: false, requestId: request)
                XCTFail("Unreadable storage must retain the guard")
            } catch let error as OnchainSendAttemptError {
                guard case .unresolved = error else { return XCTFail("Unreadable admission must stay uncertain") }
            }
            XCTAssertEqual(node.calls, 0)
            XCTAssertEqual(store.snapshot(), [original])
        }
        for error in [OnchainSendAttemptError.unresolved, .blocked(nil), .duplicate, .preDispatchCleanupFailed] {
            XCTAssertFalse(SendConfirmationView.isUnsentBlockedRequest(request, onchainPaymentStarted: false, error: error))
        }
    }

    func testAcceptedConfirmationStaysPendingUntilOriginalFollowupCompletes() async throws {
        let shopRequest = PaykitPaymentRequest.ID(
            paymentRequestId: "original-shop-order",
            counterparty: "original-merchant",
            billingPeriodStartsAt: nil
        )
        for requestId in [nil, shopRequest] as [PaykitPaymentRequest.ID?] {
            let store = MemoryAttemptStore()
            let original = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: requestId, orderId: nil,
                                              address: "bcrt1qoriginal", amountSats: 1000, isMaxAmount: false,
                                              status: .accepted, txid: txid)
            try store.save([original])
            let service = OnchainSendAttemptService(store: store)
            let route = await SendConfirmationView.acceptedOnchainRoute(
                txid: txid, requestId: requestId, localFollowupComplete: false, using: service
            )
            switch route {
            case let .onchainPending(context):
                XCTAssertNil(requestId)
                XCTAssertEqual(context.attemptId, original.id)
                XCTAssertEqual(context.walletId, original.walletId)
                XCTAssertEqual(context.txid, txid)
            case let .onchainOperationPending(context, actualRequest):
                XCTAssertEqual(actualRequest, requestId)
                XCTAssertEqual(context.attemptId, original.id)
                XCTAssertEqual(context.walletId, original.walletId)
                XCTAssertEqual(context.txid, txid)
            default: XCTFail("Accepted payment with incomplete local follow-up must stay Pending")
            }
            XCTAssertEqual(store.snapshot(), [original])
            let completedRoute = await SendConfirmationView.acceptedOnchainRoute(
                txid: txid, requestId: requestId, localFollowupComplete: true, using: service
            )
            guard case let .success(paymentId, _) = completedRoute else {
                XCTFail("Durably completed payment must show Sent")
                continue
            }
            XCTAssertEqual(paymentId, txid)
        }
    }

    func testBackupDefersUnsignedOrdinaryAndTransferAdmissions() async throws {
        let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
            kind: "software", network: "regtest", binding: String(repeating: "12", count: 32), sourceIndex: "0"
        )
        for orderId in [nil, "original-order"] as [String?] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let id = try await service.admit(
                walletId: XCTUnwrap(wallet.originalWalletId), requestId: nil, orderId: orderId,
                address: "bcrt1qoriginal", amountSats: 1000, isMaxAmount: false,
                followupContext: .init(feeSats: 100, feeRate: 1, tags: [], contact: nil, createdAt: 123),
                transferContext: orderId.map { _ in
                    .init(clientBalanceSats: 1000, txTotalSats: 1000, preTransferOnchainSats: 2000, originalOrderFeeSats: 0)
                }
            )
            do {
                _ = try await service.backupSnapshot(wallet: wallet, proofs: [])
                XCTFail("Unsigned preparation must defer the wallet snapshot")
            } catch {}
            XCTAssertEqual(store.snapshot().first?.id, id)
            XCTAssertEqual(store.snapshot().first?.blocksNewSend, true)
            XCTAssertEqual(store.snapshot().first?.canRetrySamePayment, false)
        }
    }

    func testBackupRetainsPreparedPendingReceiptForSamePaymentRecovery() async throws {
        let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
            kind: "software", network: "regtest", binding: String(repeating: "12", count: 32), sourceIndex: "0"
        )
        let store = MemoryAttemptStore()
        let original = try OnchainSendAttempt(
            id: UUID(), walletId: XCTUnwrap(wallet.originalWalletId), requestId: nil, orderId: nil,
            address: "bcrt1qoriginal", amountSats: 1000, isMaxAmount: false, status: .pending, txid: txid,
            followupContext: .init(feeSats: 100, feeRate: 1, tags: [], contact: nil, createdAt: 123),
            recoveryContext: .init(inputs: [.init(txid: String(repeating: "cd", count: 32), vout: 0)],
                                   satsPerVbyte: 1, paymentIdentity: nil, candidateTxids: [txid])
        )
        try store.save([original])
        let service = OnchainSendAttemptService(store: store)
        let snapshot = try await service.backupSnapshot(wallet: wallet, proofs: [])
        let wire = try XCTUnwrap(snapshot)
        let (restored, _) = try wire.restored(wallet: wallet, proofs: [])
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.walletId, original.walletId)
        XCTAssertEqual(restored.address, original.address)
        XCTAssertEqual(restored.amountSats, original.amountSats)
        XCTAssertEqual(restored.recoveryContext?.inputs, original.recoveryContext?.inputs)
        XCTAssertEqual(restored.recoveryContext?.candidateTxids, original.recoveryContext?.candidateTxids)
        XCTAssertTrue(restored.canRetrySamePayment)
    }

    func testReleaseMustOutbidARetryCandidateAfterARestore() async throws {
        let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
            kind: "software", network: "regtest", binding: String(repeating: "12", count: 32), sourceIndex: "0"
        )
        let retry = String(repeating: "ef", count: 32)
        let input = OnchainSendInput(txid: String(repeating: "cd", count: 32), vout: 0)
        // Original at 10 sat/vB and a retry of it at 30 sat/vB, both 141 vB: P2WPKH input, P2TR payee output, change.
        let live = try OnchainSendAttempt(
            id: UUID(), walletId: XCTUnwrap(wallet.originalWalletId), requestId: nil, orderId: nil,
            address: "bcrt1poriginal", amountSats: 10000, isMaxAmount: false, status: .unknown, txid: retry,
            followupContext: .init(feeSats: 1410, feeRate: 10, tags: [], contact: nil, createdAt: 123),
            recoveryContext: .init(inputs: [input], satsPerVbyte: 10, paymentIdentity: nil, candidateTxids: [txid, retry],
                                   candidateFeeRates: [txid: 10, retry: 30], candidateFeeSats: [txid: 1410, retry: 4230])
        )
        let store = MemoryAttemptStore()
        try store.save([live])
        let snapshot = try await OnchainSendAttemptService(store: store).backupSnapshot(wallet: wallet, proofs: [])
        let (restored, _) = try XCTUnwrap(snapshot).restored(wallet: wallet, proofs: [])
        XCTAssertEqual(restored.recoveryContext?.candidateFeeSats?[retry], 4230, "The backup carries each candidate's fee")
        // The release's first try: 2 sat/vB over the retry, on a 129 vB tx (P2WPKH output to the wallet, change).
        let release = PreparedOnchainSendDispatch(
            txid: String(repeating: "77", count: 32), inputs: [input], recipientAmountSats: 1000, miningFeeSats: 32 * 129,
            broadcast: { .accepted(txid: String(repeating: "77", count: 32)) }
        )
        XCTAssertFalse(OnchainSendAttemptService.releaseOutbids(release, live))
        XCTAssertFalse(OnchainSendAttemptService.releaseOutbids(release, restored),
                       "A release paying less than the 4230-sat retry outbids it once a restore drops the local fee evidence")
        // An older backup without the fees still bounds the retry from its rate.
        var olderBackup = restored
        olderBackup.recoveryContext?.candidateFeeSats = nil
        XCTAssertFalse(OnchainSendAttemptService.releaseOutbids(release, olderBackup))
    }

    func testRestoringTheBackupOfAPendingAttemptKeepsTheLocalAttempt() async throws {
        let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
            kind: "software", network: "regtest", binding: String(repeating: "12", count: 32), sourceIndex: "0"
        )
        let store = MemoryAttemptStore()
        var original = try OnchainSendAttempt(
            id: UUID(), walletId: XCTUnwrap(wallet.originalWalletId), requestId: nil, orderId: nil,
            address: "bcrt1qoriginal", amountSats: 1000, isMaxAmount: false, status: .unknown, txid: txid,
            followupContext: .init(feeSats: 100, feeRate: 1, tags: [], contact: nil, createdAt: 123),
            recoveryContext: .init(inputs: [.init(txid: String(repeating: "cd", count: 32), vout: 0)],
                                   satsPerVbyte: 1, paymentIdentity: nil, candidateTxids: [txid])
        )
        try store.save([original])
        let service = OnchainSendAttemptService(store: store)
        let snapshot = try await service.backupSnapshot(wallet: wallet, proofs: [])
        let wire = try XCTUnwrap(snapshot)
        let (restored, _) = try wire.restored(wallet: wallet, proofs: [])
        XCTAssertNotNil(restored.followupContext?.backupCreatedAtMillis)
        // Local-only release state the backup never carries.
        original.releaseApproved = true
        original.releaseTxid = String(repeating: "77", count: 32)
        try store.save([original])
        let reopened = OnchainSendAttemptService(store: store)
        try await reopened.restoreBackup(restored)
        XCTAssertEqual(store.snapshot(), [original])
    }

    func testInitialQueuedExpiryReleasesDefinitelyUnsentAttempt() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let deadlineDate = Date(timeIntervalSince1970: 1_800_000_000)
        sender.deadlineClock = { deadlineDate.addingTimeInterval(-1) }
        sender.onNativeQueueDispatch = { sender.deadlineClock = { deadlineDate.addingTimeInterval(1) } }
        do {
            _ = try await service.send(
                using: sender, address: "original", amountSats: sender.amount, satsPerVbyte: 1,
                utxosToSpend: nil, isMaxAmount: false,
                paymentDeadline: PaykitPreciseInstant(date: deadlineDate)
            )
            XCTFail("Queued expiry must surface a definite pre-submission failure")
        } catch OnchainSendAttemptError.preDispatch {}
        XCTAssertEqual(sender.broadcasts, 0)
        XCTAssertTrue(store.snapshot().isEmpty)
        let restarted = OnchainSendAttemptService(store: store)
        sender.onNativeQueueDispatch = nil
        _ = try await restarted.send(using: sender, address: "next", amountSats: sender.amount,
                                     satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
        XCTAssertEqual(sender.broadcasts, 1)
    }

    func testOriginalRetryChecksDeadlineAfterAuthorizationBeforeNativeDispatch() async throws {
        for expired in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                       satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
            let original = try XCTUnwrap(store.snapshot().first)
            let originalTxid = try XCTUnwrap(original.txid)
            let deadlineDate = Date(timeIntervalSince1970: 1_800_000_000)
            let deadline = PaykitPreciseInstant(date: deadlineDate)
            var dispatchTime = deadlineDate.addingTimeInterval(-1)
            sender.deadlineClock = { dispatchTime }
            sender.txid = String(repeating: "cd", count: 32)
            do {
                let result = try await service.retrySamePayment(
                    using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid),
                    paymentDeadline: deadline, authorize: { _, _ in
                        sender.onNativeQueueDispatch = { dispatchTime = deadlineDate.addingTimeInterval(expired ? 0.001 : 0) }
                    }
                )
                if expired {
                    XCTFail("Definitely unsent retry must report pre-dispatch failure")
                } else {
                    XCTAssertEqual(result, .unknown(txid: sender.txid))
                }
            } catch OnchainSendAttemptError.preDispatch {
                XCTAssertTrue(expired)
            }
            XCTAssertEqual(sender.broadcasts, expired ? 1 : 2, "An expired successor must never reach native broadcast")
            if expired {
                XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateTxids, [originalTxid])
                XCTAssertNil(store.snapshot().first?.recoveryContext?.candidateFeeRates?[sender.txid])
                let observed = try await service.observeTransaction(txid: originalTxid, walletId: original.walletId)
                XCTAssertTrue(observed, "The original must remain observable without an unsent competitor")
            }
            XCTAssertEqual(store.snapshot().first?.id, original.id)
            XCTAssertEqual(store.snapshot().first?.address, original.address)
            XCTAssertEqual(store.snapshot().first?.amountSats, original.amountSats)
            XCTAssertEqual(store.snapshot().first?.recoveryContext?.inputs, original.recoveryContext?.inputs)
            XCTAssertEqual(store.snapshot().first?.blocksNewSend, true)
        }
    }

    func testPublishedPreparedSendNativeEntryPointsRequireRunningNode() async throws {
        try await ServiceQueue.background(.ldk, wrapErrors: false) {
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent("bi717-rc69-native-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: storage) }
            let builder = Builder()
            builder.setStorageDirPath(storageDirPath: storage.path)
            let node = try builder.build()
            let payment = node.onchainPayment()
            let address = try payment.newAddress()
            XCTAssertThrowsError(try payment.prepareSendToAddress(address: address, amountSats: 1, feeRate: nil, utxosToSpend: nil)) {
                guard case .NotRunning = $0 as? NodeError else {
                    return XCTFail("Expected native NotRunning, got \($0)")
                }
            }
            XCTAssertThrowsError(try payment.prepareSendAllToAddress(address: address, retainReserves: true, feeRate: nil)) {
                guard case .NotRunning = $0 as? NodeError else {
                    return XCTFail("Expected native NotRunning, got \($0)")
                }
            }
        }
    }

    func testPreparedMaxFundingMustRespectOriginalOrderBeforeBroadcast() async throws {
        for (amount, fee, valid): (UInt64, UInt64?, Bool) in [
            (98999, 500, false), (100_001, 500, false), (99500, 500, true),
            (99500, nil, false), (99500, 501, false), (99500, UInt64.max, false),
        ] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            sender.amount = amount
            sender.miningFee = fee
            let context = OnchainSendTransferContext(clientBalanceSats: 97000, txTotalSats: 100_000,
                                                     preTransferOnchainSats: 100_000, originalOrderFeeSats: 99000)
            do {
                _ = try await service.send(using: sender, address: "original", amountSats: 99000,
                                           satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: true,
                                           orderId: "original-order", transferContext: context)
                XCTAssertTrue(valid, "Funding total must include its actual mining fee")
                XCTAssertEqual(sender.broadcasts, 1)
                XCTAssertEqual(store.snapshot().first?.amountSats, 99500)
                XCTAssertEqual(store.snapshot().first?.transferContext, context)
            } catch {
                XCTAssertFalse(valid, "Valid surplus funding must remain supported")
                XCTAssertEqual(sender.broadcasts, 0)
                XCTAssertTrue(store.snapshot().isEmpty)
            }
        }
    }

    func testPreparedReceiptIsDurableBeforeNativeDispatch() async throws {
        for max in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            sender.amount = max ? 1500 : 1234
            sender.onBroadcast = {
                let attempt = try XCTUnwrap(store.snapshot().first)
                XCTAssertEqual(attempt.recoveryContext?.inputs, sender.inputs)
                XCTAssertEqual(attempt.recoveryContext?.candidateTxids, [sender.txid])
                XCTAssertEqual(attempt.amountSats, sender.amount)
            }
            _ = try await service.send(using: sender, address: "original", amountSats: 1234,
                                       satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: max)
            XCTAssertEqual(sender.preparations, 1)
            XCTAssertEqual(sender.legacyCalls, 0)
            XCTAssertEqual(sender.broadcasts, 1)
        }
    }

    func testOrdinaryFollowupIsOwnedAcrossSuspensionAndReleasedAfterFailure() async throws {
        let store = MemoryAttemptStore()
        let attempt = OnchainSendAttempt(id: UUID(), walletId: "original-wallet", requestId: nil, orderId: nil,
                                         address: "original", amountSats: 1000, isMaxAmount: false,
                                         status: .accepted, txid: String(repeating: "ab", count: 32))
        try store.save([attempt])
        let followup = SuspendedOrdinaryFollowup()
        let service = OnchainSendAttemptService(store: store, localFollowup: followup)
        let first = Task { try? await service.resumeAcceptedOrdinarySend(walletId: attempt.walletId) }
        await followup.waitForStart()
        let competing = try? await service.resumeAcceptedOrdinarySend(walletId: attempt.walletId)
        XCTAssertNil(competing)
        let calls = await followup.callCount()
        XCTAssertEqual(calls, 1, "A competing call must not repeat a suspended activity write")
        await followup.release()
        _ = await first.value
        _ = try? await service.resumeAcceptedOrdinarySend(walletId: attempt.walletId)
        let retriedCalls = await followup.callCount()
        XCTAssertEqual(retriedCalls, calls + 1, "A failed owner must allow a later retry")
    }

    func testOriginalSignedFeeIsPersistedBeforeDispatchInsteadOfUnreadyEstimate() async throws {
        for estimate in [UInt64(0), 143] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            sender.result = .accepted(txid: sender.txid)
            _ = try await service.send(
                using: sender, address: "original", amountSats: sender.amount, satsPerVbyte: 1,
                utxosToSpend: nil, isMaxAmount: false,
                followupContext: .init(feeSats: estimate, feeRate: 1, tags: [], contact: nil, createdAt: 123),
                beforeBroadcastAttempt: {
                    XCTAssertEqual(store.snapshot().first?.followupContext?.feeSats, sender.miningFee)
                    XCTAssertEqual(sender.broadcasts, 0)
                }
            )
            XCTAssertEqual(store.snapshot().first?.followupContext?.feeSats, sender.miningFee)
        }
    }

    func testOriginalWinnerWithZeroStoredFeeUsesObservedFeeOrKeepsFollowupPending() async throws {
        for observed in [UInt64(281), nil] as [UInt64?] {
            let store = MemoryAttemptStore()
            let followup = CapturingWinningFeeFollowup()
            let service = OnchainSendAttemptService(store: store, localFollowup: followup, winningFee: { _ in observed })
            let sender = PreparedAttemptNodeMock()
            sender.miningFee = nil
            sender.result = .accepted(txid: sender.txid)
            _ = try await service.send(
                using: sender, address: "original", amountSats: sender.amount, satsPerVbyte: 1,
                utxosToSpend: nil, isMaxAmount: false,
                followupContext: .init(feeSats: 0, feeRate: 1, tags: [], contact: nil, createdAt: 123)
            )
            do {
                _ = try await service.resumeAcceptedOrdinarySend(walletId: XCTUnwrap(store.snapshot().first).walletId)
                XCTFail("The capturing local follow-up does not acknowledge completion")
            } catch {}
            XCTAssertEqual(followup.attempt?.followupContext?.feeSats, observed)
            XCTAssertEqual(store.snapshot().first?.followupContext?.feeSats, observed ?? 0)
            XCTAssertTrue(store.snapshot().first?.blocksNewSend == true)
        }
    }

    func testSuccessorFollowupRetainsWinningFeeInsteadOfOriginalFee() async throws {
        let store = MemoryAttemptStore()
        let followup = CapturingWinningFeeFollowup()
        let service = OnchainSendAttemptService(store: store, localFollowup: followup, winningFee: { _ in 281 })
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false,
                                   followupContext: .init(feeSats: 143, feeRate: 1, tags: [], contact: nil, createdAt: 123))
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        sender.miningFee = nil
        sender.result = .accepted(txid: sender.txid)
        _ = try await service.retrySamePayment(using: sender,
                                               context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                                               satsPerVbyte: 2, authorize: { _, _ in })
        do { _ = try await service.resumeAcceptedOrdinarySend(walletId: original.walletId) } catch {}
        XCTAssertEqual(followup.attempt?.followupContext?.feeRate, 2)
        XCTAssertEqual(followup.attempt?.followupContext?.feeSats, 281)
        XCTAssertEqual(followup.attempt?.txid, sender.txid)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, false)
    }

    func testAcceptedSuccessorUsesPreparedFeeAfterRestartWithoutWalletHistory() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        sender.miningFee = 143
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false,
                                   followupContext: .init(feeSats: 0, feeRate: 1, tags: [], contact: nil, createdAt: 123))
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        sender.miningFee = 281
        sender.result = .accepted(txid: sender.txid)
        _ = try await service.retrySamePayment(using: sender,
                                               context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                                               satsPerVbyte: 2, authorize: { _, _ in })
        let restored = MemoryAttemptStore()
        try restored.save(JSONDecoder().decode([OnchainSendAttempt].self, from: JSONEncoder().encode(store.snapshot())))
        let followup = CapturingWinningFeeFollowup()
        let restarted = OnchainSendAttemptService(store: restored, localFollowup: followup, winningFee: { _ in nil })
        do { _ = try await restarted.resumeAcceptedOrdinarySend(walletId: original.walletId) } catch {}
        XCTAssertEqual(followup.attempt?.txid, sender.txid)
        XCTAssertEqual(followup.attempt?.followupContext?.feeSats, 281)
        XCTAssertEqual(followup.attempt?.followupContext?.feeRate, 2)
        XCTAssertEqual(restored.snapshot().first?.blocksNewSend, true, "Failed activity persistence must remain guarded")
    }

    func testWinningFeeCalculationUsesExactPreviousOutputAndRejectsMissingOrInvalidDetails() throws {
        let parentId = String(repeating: "ef", count: 32)
        let details = LDKNode.TransactionDetails(amountSats: -1000,
                                                 inputs: [.init(txid: parentId, vout: 1, scriptsig: "", witness: [], sequence: UInt32.max - 2)],
                                                 outputs: [
                                                     .init(
                                                         scriptpubkey: "recipient",
                                                         scriptpubkeyType: nil,
                                                         scriptpubkeyAddress: nil,
                                                         value: 1000,
                                                         n: 0
                                                     ),
                                                     .init(
                                                         scriptpubkey: "change",
                                                         scriptpubkeyType: nil,
                                                         scriptpubkeyAddress: nil,
                                                         value: 18719,
                                                         n: 1
                                                     ),
                                                 ])
        let parent = LDKNode.TransactionDetails(amountSats: 20000, inputs: [],
                                                outputs: [.init(
                                                    scriptpubkey: "wallet",
                                                    scriptpubkeyType: nil,
                                                    scriptpubkeyAddress: nil,
                                                    value: 20000,
                                                    n: 1
                                                )])
        XCTAssertEqual(try OnchainSendLocalFollowup.exactFee(details: details) { id in
            XCTAssertEqual(id, parentId)
            return parent
        }, 281)
        XCTAssertNil(try OnchainSendLocalFollowup.exactFee(details: details, previous: { _ in nil }))
        var wrong = parent
        wrong.outputs[0].n = 0
        XCTAssertThrowsError(try OnchainSendLocalFollowup.exactFee(details: details, previous: { _ in wrong }))
        wrong = parent
        wrong.outputs[0].value = 100
        XCTAssertThrowsError(try OnchainSendLocalFollowup.exactFee(details: details, previous: { _ in wrong }))
    }

    func testReceivedOriginalCannotWinWhileReplacementIsUnresolved() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
        let original = try XCTUnwrap(store.snapshot().first)
        let originalTxid = try XCTUnwrap(original.txid)
        sender.txid = String(repeating: "cd", count: 32)
        _ = try await service.retrySamePayment(using: sender,
                                               context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid),
                                               satsPerVbyte: 2, authorize: { _, _ in })
        let before = store.snapshot()
        let received = try await service.observeTransaction(txid: originalTxid, walletId: original.walletId)
        XCTAssertFalse(received, "An unconfirmed original must not finalize a multi-candidate payment")
        XCTAssertEqual(store.snapshot(), before)
        let confirmed = try await service.observeConfirmedTransaction(txid: sender.txid)
        XCTAssertTrue(confirmed)
        let winner = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(winner.id, original.id)
        XCTAssertEqual(winner.walletId, original.walletId)
        XCTAssertEqual(winner.amountSats, original.amountSats)
        XCTAssertEqual(winner.recoveryContext?.inputs, original.recoveryContext?.inputs)
        XCTAssertEqual(winner.txid, sender.txid)
        XCTAssertEqual(winner.status, .accepted)
        XCTAssertFalse(winner.localFollowupComplete)
    }

    func testOriginalWinnerRetainsItsRateAfterHigherFeeSuccessorIsPrepared() async throws {
        let store = MemoryAttemptStore()
        let followup = CapturingWinningFeeFollowup()
        let service = OnchainSendAttemptService(store: store, localFollowup: followup, winningFee: { _ in 143 })
        let sender = PreparedAttemptNodeMock()
        sender.miningFee = 143
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false,
                                   followupContext: .init(feeSats: 143, feeRate: 1, tags: [], contact: nil, createdAt: 123))
        let original = try XCTUnwrap(store.snapshot().first)
        let originalTxid = try XCTUnwrap(original.txid)
        sender.txid = String(repeating: "cd", count: 32)
        sender.miningFee = 281
        _ = try await service.retrySamePayment(using: sender,
                                               context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid),
                                               satsPerVbyte: 2, authorize: { _, _ in })
        _ = try await service.observeTransaction(txid: originalTxid, walletId: original.walletId, isConfirmed: true)
        do { _ = try await service.resumeAcceptedOrdinarySend(walletId: original.walletId) } catch {}
        XCTAssertEqual(followup.attempt?.followupContext?.feeRate, 1)
        XCTAssertEqual(followup.attempt?.followupContext?.feeSats, 143)
        XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateFeeRates,
                       [originalTxid: 1, sender.txid: 2])
    }

    func testMissingSuccessorFeeKeepsLocalFollowupGuardedWithoutStaleActivity() async throws {
        let store = MemoryAttemptStore()
        let followup = CapturingWinningFeeFollowup()
        let service = OnchainSendAttemptService(store: store, localFollowup: followup, winningFee: { _ in nil })
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false,
                                   followupContext: .init(feeSats: 143, feeRate: 1, tags: [], contact: nil, createdAt: 123))
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        sender.miningFee = nil
        sender.result = .accepted(txid: sender.txid)
        _ = try await service.retrySamePayment(using: sender,
                                               context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                                               satsPerVbyte: 2, authorize: { _, _ in })
        do { _ = try await service.resumeAcceptedOrdinarySend(walletId: original.walletId); XCTFail("Missing successor fee must stay pending")
        } catch {}
        XCTAssertNil(followup.attempt)
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
        XCTAssertEqual(store.snapshot().first?.blocksNewSend, true)
    }

    func testRetryApprovesExactPreparedFeeBeforeAuthenticationAndDispatch() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        sender.miningFee = 800
        var approved = false
        _ = try await service.retrySamePayment(
            using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
            satsPerVbyte: 2, approvePrepared: { prepared in
                XCTAssertEqual(prepared.miningFeeSats, 800)
                XCTAssertEqual(prepared.recipientAmountSats, original.amountSats)
                XCTAssertEqual(prepared.txid, sender.txid)
                XCTAssertEqual(sender.broadcasts, 1)
                XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateFeeSats?[prepared.txid], 800)
                approved = true
            }, authorize: { _, _ in XCTAssertTrue(approved) }
        )
        XCTAssertEqual(sender.preparations, 2)
        XCTAssertEqual(sender.broadcasts, 2)
        XCTAssertEqual(store.snapshot().first?.txid, sender.txid)
        XCTAssertEqual(store.snapshot().first?.status, .unknown)
        XCTAssertEqual(store.snapshot().first?.blocksNewSend, true)
    }

    func testRetainedCandidateRejectsConflictingPreparedFee() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
        let original = try XCTUnwrap(store.snapshot().first)
        sender.miningFee = 700
        do {
            _ = try await service.retrySamePayment(using: sender,
                                                   context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                                                   authorize: { _, _ in XCTFail("Conflicting receipt must not reach authorization") })
            XCTFail("A transaction ID cannot acquire another mining fee")
        } catch OnchainSendAttemptError.unresolved {}
        XCTAssertEqual(sender.broadcasts, 1)
        XCTAssertEqual(store.snapshot(), [original])
    }

    func testCancelledFeeApprovalDoesNotSubmitOrRetainNewCandidate() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        var authenticated = false
        do {
            _ = try await service.retrySamePayment(
                using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                satsPerVbyte: 2, approvePrepared: { _ in throw CancellationError() },
                authorize: { _, _ in authenticated = true }
            )
            XCTFail("Cancelled fee approval must stop the retry")
        } catch is CancellationError {}
        XCTAssertFalse(authenticated)
        XCTAssertEqual(sender.broadcasts, 1)
        XCTAssertEqual(store.snapshot().first, original)
        do {
            _ = try await service.retrySamePayment(
                using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                satsPerVbyte: 1000, authorize: { _, _ in authenticated = true }
            )
            XCTFail("Recovery must share the normal fee ceiling")
        } catch {}
        XCTAssertEqual(sender.preparations, 2)
    }

    func testMaxRetryRejectsFeeIncreaseBeforePreparationOrAuthorization() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: true)
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        var authorizationCount = 0
        do {
            _ = try await service.retrySamePayment(
                using: sender, context: OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                satsPerVbyte: 3, authorize: { _, _ in authorizationCount += 1 }
            )
            XCTFail("A send-all retry cannot fund a higher fee without changing the original amount or inputs")
        } catch {}
        XCTAssertEqual(sender.preparations, 1)
        XCTAssertEqual(sender.broadcasts, 1)
        XCTAssertEqual(authorizationCount, 0)
        XCTAssertEqual(store.snapshot().first, original)
    }

    func testExplicitRetryUsesOriginalMaxReceiptAndRetainsEveryCandidate() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: 1234,
                                   satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: true)
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        var authorizationCount = 0
        let result = try await service.retrySamePayment(
            using: sender, context: OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: original.txid),
            satsPerVbyte: 2,
            authorize: { admitted, feeRate in
                authorizationCount += 1
                XCTAssertEqual(admitted.id, original.id)
                XCTAssertEqual(feeRate, 2)
            }
        )
        XCTAssertEqual(result, .unknown(txid: sender.txid))
        XCTAssertEqual(sender.lastAddress, "original")
        XCTAssertEqual(sender.lastAmount, original.amountSats)
        XCTAssertEqual(authorizationCount, 1)
        XCTAssertEqual(sender.lastFeeRate, 2)
        XCTAssertEqual(sender.lastMax, false)
        XCTAssertEqual(sender.lastInputs, sender.inputs)
        XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateTxids, try [XCTUnwrap(original.txid), sender.txid])
        XCTAssertEqual(sender.broadcasts, 2)
    }

    func testOriginalObservationWhileRetryPreparesStopsAnotherBroadcast() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
        let original = try XCTUnwrap(store.snapshot().first)
        let originalTxid = try XCTUnwrap(original.txid)
        sender.txid = String(repeating: "cd", count: 32)
        sender.onPrepare = { _ = try await service.observeConfirmedTransaction(txid: originalTxid) }
        let result = try await service.retrySamePayment(
            using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid), authorize: { _, _ in }
        )
        XCTAssertEqual(result, .accepted(txid: originalTxid))
        XCTAssertEqual(sender.broadcasts, 1)
        XCTAssertEqual(store.snapshot().first?.txid, originalTxid)
    }

    func testLateOriginalAcceptanceWinsOverUnknownOrRefusedSuccessor() async throws {
        for refused in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                       satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
            let original = try XCTUnwrap(store.snapshot().first)
            let originalTxid = try XCTUnwrap(original.txid)
            sender.txid = String(repeating: "cd", count: 32)
            sender.result = refused ? .rejected(txid: sender.txid, reason: "fixture refusal") : .unknown(txid: sender.txid)
            sender.onBroadcast = {
                XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateTxids, [originalTxid, sender.txid])
                _ = try await service.observeConfirmedTransaction(txid: originalTxid)
                do {
                    _ = try await service.admit(walletId: original.walletId, requestId: nil, orderId: nil,
                                                address: "disjoint", amountSats: 1, isMaxAmount: false)
                    XCTFail("An in-flight sibling allowed another operation")
                } catch {}
            }
            let result = try await service.retrySamePayment(
                using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid), authorize: { _, _ in }
            )
            XCTAssertEqual(result, .accepted(txid: originalTxid))
            XCTAssertEqual(store.snapshot().first?.status, .accepted)
            XCTAssertEqual(store.snapshot().first?.txid, originalTxid)
            let restarted = OnchainSendAttemptService(store: store)
            let loaded = try await restarted.ordinaryPendingAttempt(context: .init(
                attemptId: original.id, walletId: original.walletId, txid: sender.txid
            ))
            XCTAssertEqual(loaded?.txid, originalTxid)
        }
    }

    func testRetryRejectsChangedAmountInputsWalletAndContextWithoutBroadcast() async throws {
        for invalid in 0 ..< 5 {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                       satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
            let original = try XCTUnwrap(store.snapshot().first)
            sender.txid = String(repeating: "cd", count: 32)
            if invalid == 0 {
                sender.amount -= 1
            }
            if invalid == 1 {
                sender.inputs = [OnchainSendInput(txid: String(repeating: "aa", count: 32), vout: 1)]
            }
            if invalid == 2 {
                sender.currentWalletIndex = 1
            }
            if invalid == 4 {
                sender.onPrepare = { sender.currentWalletIndex = 1 }
            }
            let context = OnchainSendPendingContext(attemptId: invalid == 3 ? UUID() : original.id,
                                                    walletId: original.walletId, txid: original.txid)
            do { _ = try await service.retrySamePayment(using: sender, context: context, authorize: { _, _ in
            }); XCTFail("Invalid recovery dispatched") } catch {}
            XCTAssertEqual(sender.broadcasts, 1)
            XCTAssertEqual(store.snapshot().first, original)
        }
    }

    func testRetryReceiptSaveOrAuthorizationFailureRetainsOriginalGuard() async throws {
        for saveFails in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                       satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
            let original = try XCTUnwrap(store.snapshot().first)
            sender.txid = String(repeating: "cd", count: 32)
            if saveFails {
                sender.onPrepare = { store.failSave = true }
            }
            do {
                _ = try await service.retrySamePayment(
                    using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                    authorize: {
                        _, _ in if !saveFails {
                            throw MemoryAttemptStoreError.failed
                        }
                    }
                )
                XCTFail("Failed authorization/receipt save dispatched")
            } catch {}
            store.failSave = false
            let retained = try XCTUnwrap(store.snapshot().first)
            XCTAssertEqual(retained.id, original.id)
            XCTAssertEqual(retained.txid, original.txid)
            XCTAssertEqual(retained.status, original.status)
            XCTAssertEqual(retained.amountSats, original.amountSats)
            XCTAssertEqual(retained.recoveryContext?.inputs, original.recoveryContext?.inputs)
            XCTAssertEqual(sender.broadcasts, 1)
            do { _ = try await service.send(using: sender, address: "disjoint", amountSats: 1,
                                            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false); XCTFail("Original guard was released") } catch {}
        }
    }

    func testCancelledRetryDropsOnlyItsUnsubmittedCandidateAndOriginalCanComplete() async throws {
        for walletChanges in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            _ = try await service.send(using: sender, address: "bcrt1qoriginal", amountSats: sender.amount,
                                       satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
            let original = try XCTUnwrap(store.snapshot().first)
            let originalTxid = try XCTUnwrap(original.txid)
            let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
                kind: "software", network: "regtest", binding: String(repeating: "12", count: 32), sourceIndex: "0"
            )
            let beforeRetry = try await service.backupSnapshot(wallet: wallet, proofs: [])
            XCTAssertNotNil(beforeRetry)
            sender.txid = String(repeating: "cd", count: 32)
            do {
                _ = try await service.retrySamePayment(
                    using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid),
                    satsPerVbyte: 2, authorize: { _, _ in
                        do {
                            _ = try await service.backupSnapshot(wallet: wallet, proofs: [])
                            XCTFail("Authorization must not upload the undispatched retry candidate")
                        } catch {}
                        if walletChanges {
                            sender.currentWalletIndex = 1
                        } else {
                            throw CancellationError()
                        }
                    }
                )
                XCTFail("Pre-dispatch exit submitted the successor")
            } catch {}
            let retained = try XCTUnwrap(store.snapshot().first)
            XCTAssertEqual(retained.id, original.id)
            XCTAssertEqual(retained.recoveryContext?.inputs, original.recoveryContext?.inputs)
            XCTAssertEqual(retained.recoveryContext?.candidateTxids, [originalTxid])
            XCTAssertNil(retained.recoveryContext?.candidateFeeRates?[sender.txid])
            XCTAssertNil(retained.recoveryContext?.candidateFeeSats?[sender.txid])
            XCTAssertEqual(sender.broadcasts, 1)
            XCTAssertTrue(retained.blocksNewSend)
            let restarted = OnchainSendAttemptService(store: store)
            let observed = try await restarted.observeTransaction(txid: originalTxid, walletId: original.walletId)
            XCTAssertTrue(observed, "an undispatched successor must not suppress the original received event")
            XCTAssertEqual(store.snapshot().first?.txid, originalTxid)
            XCTAssertEqual(store.snapshot().first?.status, .accepted)
        }
    }

    func testCancelledRetryCleanupFailureRetainsTheOriginalGuard() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "cd", count: 32)
        do {
            _ = try await service.retrySamePayment(
                using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                satsPerVbyte: 2, authorize: { _, _ in
                    store.failSave = true
                    throw CancellationError()
                }
            )
            XCTFail("Failed cleanup submitted the successor")
        } catch let error as OnchainSendAttemptError {
            guard case .unresolved = error else { return XCTFail("Failed cleanup was not reported as unresolved") }
        } catch { XCTFail("Failed cleanup was not reported as unresolved: \(error)") }
        store.failSave = false
        XCTAssertEqual(sender.broadcasts, 1)
        XCTAssertEqual(store.snapshot().first?.id, original.id)
        XCTAssertTrue(store.snapshot().first?.blocksNewSend == true)
        do {
            _ = try await service.send(using: sender, address: "different", amountSats: 1,
                                       satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
            XCTFail("Failed cleanup released the original payment")
        } catch {}
        XCTAssertEqual(sender.broadcasts, 1)
    }

    func testAmbiguousGuardWithoutReceiptCannotRetryAndWrongWalletCannotPromote() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = AttemptNodeMock(result: .unknown(txid: txid))
        let id = try await service.admit(walletId: walletId, requestId: nil, orderId: nil,
                                         address: "original", amountSats: 1234, isMaxAmount: false)
        try await service.record(.unknown(txid: txid), attemptId: id)
        let original = try XCTUnwrap(store.snapshot().first)
        let wrongWallet = try await service.observeTransaction(txid: txid, walletId: "another-wallet")
        XCTAssertFalse(wrongWallet)
        XCTAssertEqual(store.snapshot().first, original)
        do {
            _ = try await service.retrySamePayment(
                using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: txid), authorize: { _, _ in }
            )
            XCTFail("Missing receipt permitted an unconstrained recovery")
        } catch {}
        XCTAssertEqual(sender.calls, 0)
    }

    func testFirstReceiptWriteFailureNeverBroadcastsAndRetainsDurableGuard() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        sender.onPrepare = { store.failSave = true }
        do {
            _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                       satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
            XCTFail("Receipt persistence failure broadcast")
        } catch {}
        store.failSave = false
        XCTAssertEqual(sender.broadcasts, 0)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
        XCTAssertNil(store.snapshot().first?.recoveryContext)
    }

    func testConstrainedConstructionAndTransportErrorsAreActionableWithoutReleasingOriginal() async throws {
        for construction in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                       satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
            let original = try XCTUnwrap(store.snapshot().first)
            sender.onPrepare = {
                if construction {
                    throw NodeError.InsufficientFunds(message: "raw native fee detail")
                }
                throw NodeError.ConnectionFailed(message: "raw native transport detail")
            }
            do {
                _ = try await service.retrySamePayment(
                    using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                    satsPerVbyte: 3, authorize: { _, _ in XCTFail("Preparation failure prompted authorization") }
                )
                XCTFail("Failed preparation dispatched")
            } catch let error as OnchainSendAttemptError {
                if construction {
                    guard case .retryConstruction = error else { return XCTFail("Missing fee/headroom explanation") }
                } else {
                    guard case .retryUnavailable = error else { return XCTFail("Missing uncertainty/connection explanation") }
                }
                XCTAssertFalse(error.localizedDescription.contains("raw native"))
            }
            XCTAssertEqual(store.snapshot().first, original)
            XCTAssertEqual(sender.broadcasts, 1)
        }
    }

    func testConcurrentAdmissionPersistsOnlyOnePendingAttempt() async {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let walletId = walletId

        let admitted = await withTaskGroup(of: UUID?.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try? await service.admit(
                        walletId: walletId,
                        requestId: nil,
                        orderId: nil,
                        address: "bcrt1qexample",
                        amountSats: 1000,
                        isMaxAmount: false
                    )
                }
            }
            var ids: [UUID] = []
            for await id in group {
                if let id {
                    ids.append(id)
                }
            }
            return ids
        }

        XCTAssertEqual(admitted.count, 1)
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testReadAndWriteFailuresPreventAdmission() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        store.failLoad = true
        do {
            _ = try await admit(service)
            XCTFail("Read failure admitted a send")
        } catch {}

        store.failLoad = false
        store.failSave = true
        do {
            _ = try await admit(service)
            XCTFail("Write failure admitted a send")
        } catch {}
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testUnsignedOrdinaryAttemptDoesNotBlockAfterServiceRestart() async throws {
        for orderId in [nil, "original-order"] {
            let store = MemoryAttemptStore()
            let originalService = OnchainSendAttemptService(store: store)
            _ = try await originalService.admit(
                walletId: WalletScope.default, requestId: nil, orderId: orderId,
                address: "bcrt1qexample", amountSats: 1000, isMaxAmount: false
            )
            let live = try await originalService.unresolvedAttempt(walletId: WalletScope.default)
            XCTAssertNotNil(live, "A live preparation must remain guarded")
            let restarted = OnchainSendAttemptService(store: store)
            let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
                kind: "software", network: "regtest", binding: String(repeating: "12", count: 32), sourceIndex: "0"
            )
            let snapshot = try await restarted.backupSnapshot(wallet: wallet, proofs: [])
            XCTAssertNil(snapshot, "An unsigned abandoned admission must not stall wallet backup")
            let unresolved = try await restarted.unresolvedAttempt(walletId: WalletScope.default)
            XCTAssertNil(unresolved, "No signed receipt means native dispatch could not have happened")
            _ = try await admit(restarted)
        }
    }

    func testUnsignedShopAttemptDoesNotBlockAfterServiceRestart() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        _ = try await service.admit(
            walletId: WalletScope.default,
            requestId: .init(paymentRequestId: "original-request", counterparty: "payer", billingPeriodStartsAt: nil),
            orderId: nil, address: "bcrt1qexample", amountSats: 1000, isMaxAmount: false
        )
        let live = try await service.unresolvedAttempt(walletId: WalletScope.default)
        XCTAssertNotNil(live, "Current-process Shop preparation must remain guarded")
        let restarted = OnchainSendAttemptService(store: store)
        let wallet = PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet(
            kind: "software", network: "regtest", binding: String(repeating: "12", count: 32), sourceIndex: "0"
        )
        let backup = try await restarted.backupSnapshot(wallet: wallet, proofs: [])
        XCTAssertNil(backup, "An unsigned abandoned Shop admission must not stall wallet backup")
        let pending = try await restarted.unresolvedAttempt(walletId: WalletScope.default)
        XCTAssertNil(pending, "Proof-start cannot precede persistence of the signed receipt")
        _ = try await admit(restarted)
    }

    func testRejectedAndUnknownRetainTxidAndBlockAnotherSend() async throws {
        for result in [OnchainSendResult.rejected(txid: txid, reason: "non-final"), .unknown(txid: txid)] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let id = try await admit(service)
            try await service.record(result, attemptId: id)
            XCTAssertEqual(store.snapshot().first?.txid, txid)
            do {
                _ = try await admit(service)
                XCTFail("Unresolved outcome admitted a second send")
            } catch {}
        }
    }

    func testAcceptedIsDurableAndAllowsDistinctNewSend() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let firstId = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: firstId)
        try await service.acknowledgeLocalFollowup(txid: txid)
        let nextId = try await admit(service)

        XCTAssertNotEqual(firstId, nextId)
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testAcceptedOrderCannotBeFundedAgain() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await service.admit(
            walletId: walletId, requestId: nil, orderId: "order-1",
            address: "bcrt1qexample", amountSats: 1000, isMaxAmount: false
        )
        try await service.record(.accepted(txid: txid), attemptId: id)
        try await service.acknowledgeLocalFollowup(txid: txid)

        do {
            _ = try await service.admit(
                walletId: walletId, requestId: nil, orderId: "order-1",
                address: "bcrt1qexample", amountSats: 1000, isMaxAmount: false
            )
            XCTFail("Accepted order admitted a second funding payment")
        } catch let error as OnchainSendAttemptError {
            guard case .duplicate = error else { return XCTFail("Expected a duplicate-payment guard") }
        }
    }

    func testOutcomeWriteFailureRetainsPendingGuard() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        store.failSave = true
        do {
            try await service.record(.accepted(txid: txid), attemptId: id)
            XCTFail("Outcome write unexpectedly succeeded")
        } catch {}
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testOnlyMatchingPreDispatchGuardCanBeCleared() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)

        try await service.clearBeforeDispatch(attemptId: UUID())
        XCTAssertEqual(store.snapshot().first?.id, id)

        try await service.clearBeforeDispatch(attemptId: id)
        XCTAssertTrue(store.snapshot().isEmpty)

        let acceptedId = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: acceptedId)
        try await service.clearBeforeDispatch(attemptId: acceptedId)
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
    }

    func testOnlyExactConfirmedTxidResolvesUnknownAttempt() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        try await service.record(.unknown(txid: txid), attemptId: id)

        let unrelatedObserved = try await service.observeConfirmedTransaction(txid: String(repeating: "cd", count: 32))
        XCTAssertFalse(unrelatedObserved)
        XCTAssertEqual(store.snapshot().first?.status, .unknown)
        let exactObserved = try await service.observeConfirmedTransaction(txid: txid)
        XCTAssertTrue(exactObserved)
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
    }

    func testPostBroadcastReadFailurePreservesResultAndExactPendingContext() async throws {
        for retry in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            var original: OnchainSendAttempt?
            if retry {
                _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                           satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
                original = try XCTUnwrap(store.snapshot().first)
                sender.txid = String(repeating: "cd", count: 32)
            }
            sender.result = .accepted(txid: sender.txid)
            sender.onBroadcast = { store.failLoad = true }
            do {
                let result: OnchainSendResult = if let original {
                    try await service.retrySamePayment(using: sender,
                                                       context: .init(
                                                           attemptId: original.id,
                                                           walletId: original.walletId,
                                                           txid: original.txid
                                                       ),
                                                       satsPerVbyte: 2, authorize: { _, _ in })
                } else {
                    try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                           satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
                }
                XCTAssertEqual(result, .accepted(txid: sender.txid))
                let context = try await service.pendingContext(txid: sender.txid)
                XCTAssertEqual(context?.attemptId, store.snapshot().first?.id)
                XCTAssertEqual(context?.walletId, store.snapshot().first?.walletId)
                XCTAssertEqual(context?.txid, sender.txid)
            } catch { XCTFail("Post-dispatch read failure escaped: \(error)") }
            store.failLoad = false
            let restarted = OnchainSendAttemptService(store: store)
            do {
                _ = try await restarted.send(using: sender, address: "other", amountSats: sender.amount,
                                             satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
                XCTFail("Restart released the original guard")
            } catch {}
            XCTAssertEqual(sender.broadcasts, retry ? 2 : 1)
        }
    }

    func testSendPreservesAcceptedWhenOutcomeStorageFailsAndRestartBlocksDispatch() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        do {
            let result = try await service.send(
                using: node, address: "bcrt1qexample", amountSats: 1000,
                satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
            ) {
                store.failSave = true
            }
            guard case let .accepted(returnedTxid) = result else { return XCTFail("Lost known acceptance") }
            XCTAssertEqual(returnedTxid, txid)
        } catch {
            XCTFail("Known Accepted result became a generic error: \(error)")
        }
        XCTAssertEqual(node.calls, 1)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
        XCTAssertEqual(store.snapshot().first?.txid, txid, "Prepared receipt must survive outcome-storage failure")
        XCTAssertFalse(store.snapshot().first?.recoveryContext?.inputs.isEmpty ?? true)
        store.failSave = false
        let restarted = OnchainSendAttemptService(store: store)
        do {
            _ = try await restarted.send(
                using: node, address: "bcrt1qother", amountSats: 2000,
                satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: true
            )
            XCTFail("Restart bypassed pending guard")
        } catch {}
        XCTAssertEqual(node.calls, 1)
    }

    func testCompletedOrdinarySendsDoNotAccumulateHistory() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        for _ in 0 ..< 50 {
            let id = try await admit(service)
            try await service.record(.accepted(txid: txid), attemptId: id)
            try await service.acknowledgeLocalFollowup(txid: txid)
            XCTAssertEqual(store.snapshot().count, 1, "Attempt guard grew into ordinary send history")
        }
        _ = try await admit(service)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testCompletedOrdinaryGuardCanBeReplacedAcrossWallets() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: id)
        do {
            _ = try await service.admit(
                walletId: "node-1", requestId: nil, orderId: nil,
                address: "bcrt1qother", amountSats: 2000, isMaxAmount: false
            )
            XCTFail("Incomplete accepted follow-up stopped guarding other wallets")
        } catch {}
        try await service.acknowledgeLocalFollowup(txid: txid)
        _ = try await service.admit(
            walletId: "node-1", requestId: nil, orderId: nil,
            address: "bcrt1qother", amountSats: 2000, isMaxAmount: false
        )
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot().first?.walletId, "node-1")
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testWalletOrNodeChangeDuringCallbackDoesNotDispatch() async throws {
        for changeWalletIndex in [true, false] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            do {
                _ = try await service.send(
                    using: node, address: "bcrt1qexample", amountSats: 1000,
                    satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
                ) {
                    if changeWalletIndex {
                        node.currentWalletIndex = 1
                    } else {
                        node.dispatchNode = NSObject()
                    }
                }
                XCTFail("Dispatch used a different wallet or node after admission")
            } catch let error as OnchainSendAttemptError {
                guard case .preDispatch = error else { return XCTFail("Expected known pre-dispatch failure") }
            }
            XCTAssertEqual(node.calls, 0)
            XCTAssertTrue(store.snapshot().isEmpty, "Known pre-dispatch failure retained an attempt")
        }
    }

    func testAcceptedBlocksNewSendUntilMatchingDurableFollowup() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: id)
        try await service.acknowledgeLocalFollowup(txid: String(repeating: "cd", count: 32))
        do { _ = try await admit(service); XCTFail("Accepted without follow-up admitted new send") } catch {}
        store.failSave = true
        do { try await service.acknowledgeLocalFollowup(txid: txid); XCTFail("Follow-up save should fail") } catch {}
        store.failSave = false
        let restarted = OnchainSendAttemptService(store: store)
        do { _ = try await admit(restarted); XCTFail("Restart lost incomplete follow-up") } catch {}
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, false)
        try await restarted.acknowledgeLocalFollowup(txid: txid)
        _ = try await admit(restarted)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testAcceptedOrderResumesWithoutAnotherNodeCallAfterRestart() async throws {
        let store = MemoryAttemptStore()
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let service = OnchainSendAttemptService(store: store)
        _ = try await send(service, node: node, orderId: "order-1")
        let restarted = OnchainSendAttemptService(store: store)
        let result = try await send(restarted, node: node, orderId: "order-1", isMaxAmount: true)
        guard case let .accepted(savedTxid) = result else { return XCTFail("Lost accepted prior result") }
        XCTAssertEqual(savedTxid, txid)
        XCTAssertEqual(node.calls, 1)
    }

    @MainActor
    func testActualSendSerializesFixedMaxAndTransferBeforeNodeDispatch() async {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        node.preparedMiningFeeSats = 100
        let preparation = SuspendedOnchainPreparation()
        node.onPrepare = { await preparation.suspend() }
        node.onSend = { XCTAssertEqual(store.snapshot().first?.status, .pending) }
        let first = Task {
            try? await service.send(
                using: node, address: "bcrt1qexample", amountSats: 1000, satsPerVbyte: 1,
                utxosToSpend: nil, isMaxAmount: true, orderId: "order",
                transferContext: OnchainSendTransferContext(
                    clientBalanceSats: 900, txTotalSats: 1100,
                    preTransferOnchainSats: 1100, originalOrderFeeSats: 1000
                )
            )
        }
        await preparation.waitForStart()
        let request = PaykitPaymentRequest.ID(paymentRequestId: "new-request", counterparty: "merchant", billingPeriodStartsAt: nil)
        for unreadable in [false, true] {
            store.failLoad = unreadable
            do {
                _ = try await service.send(using: node, address: "new", amountSats: 2000, satsPerVbyte: 1,
                                           utxosToSpend: nil, isMaxAmount: false, requestId: request,
                                           beforeBroadcastAttempt: { XCTFail("Competing request was authorized") })
                XCTFail("Competing request was admitted")
            } catch {
                XCTAssertEqual(SendConfirmationView.isUnsentBlockedRequest(request, onchainPaymentStarted: false, error: error), !unreadable)
            }
        }
        store.failLoad = false
        let competingSends = await withTaskGroup(of: Bool.self) { group in
            for index in 1 ..< 20 {
                group.addTask {
                    do {
                        _ = try await service.send(
                            using: node, address: "bcrt1qexample", amountSats: 1000, satsPerVbyte: 1,
                            utxosToSpend: nil, isMaxAmount: index % 2 == 0, orderId: index % 3 == 0 ? "order" : nil,
                            transferContext: index % 3 == 0 ? OnchainSendTransferContext(
                                clientBalanceSats: 900, txTotalSats: 1100,
                                preTransferOnchainSats: 1100, originalOrderFeeSats: 1000
                            ) : nil
                        )
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await sent in group where sent {
                count += 1
            }
            return count
        }
        XCTAssertEqual(competingSends, 0)
        XCTAssertEqual(node.calls, 0, "Competing sends must be blocked before native dispatch")
        await preparation.release()
        let result = await first.value
        XCTAssertEqual(result, .unknown(txid: txid))
        XCTAssertEqual(node.calls, 1)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testCallbackFailuresReleaseGuardWithoutDispatch() async throws {
        for error in [NodeError.NotRunning(message: "callback failure") as Error, CancellationError(), PaykitPaymentRequestError.requestUnavailable] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            do {
                _ = try await service.send(
                    using: node, address: "bcrt1qexample", amountSats: 1000,
                    satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
                ) { throw error }
                XCTFail("Callback failure succeeded")
            } catch let error as OnchainSendAttemptError {
                guard case .preDispatch = error else { return XCTFail("Proven callback failure was not classified before dispatch") }
            }
            XCTAssertEqual(node.calls, 0)
            XCTAssertTrue(store.snapshot().isEmpty)
            _ = try await send(service, node: node)
            XCTAssertEqual(node.calls, 1, "Safe callback release must admit a later payment")
        }
    }

    func testCallbackReleaseWriteFailureRetainsGuardWithoutDispatch() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        do {
            _ = try await service.send(
                using: node, address: "bcrt1qexample", amountSats: 1000,
                satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
            ) {
                store.failSave = true
                throw CancellationError()
            }
            XCTFail("Callback failure succeeded")
        } catch let error as OnchainSendAttemptError {
            guard case .unresolved = error else { return XCTFail("Release storage failure lost the guard") }
        }
        XCTAssertEqual(node.calls, 0)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
        store.failSave = false
        do { _ = try await send(service, node: node); XCTFail("Uncleared guard allowed dispatch") } catch {}
        XCTAssertEqual(node.calls, 0)
    }

    func testOnlyNodePreDispatchErrorReleasesGuardAndSaveFailureRetainsIt() async throws {
        for failRelease in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            node.preparationError = NodeError.NotRunning(message: "not running")
            node.onPrepare = { store.failSave = failRelease }
            do { _ = try await send(service, node: node); XCTFail("Node error succeeded") } catch let error as OnchainSendAttemptError {
                if failRelease {
                    guard case .unresolved = error else { return XCTFail("Release write failure lost guard") }
                } else {
                    guard case .preDispatch = error else { return XCTFail("Proven pre-dispatch error not released") }
                }
            }
            XCTAssertEqual(store.snapshot().isEmpty, !failRelease)
        }
    }

    func testGenericNodeWorkflowErrorsRetainGuard() async throws {
        for error in [MemoryAttemptStoreError.failed as Error, CancellationError()] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            node.error = error
            let result = try await send(service, node: node)
            XCTAssertEqual(result, .unknown(txid: txid))
            XCTAssertEqual(store.snapshot().first?.status, .unknown)
        }
    }

    func testRejectedAndUnknownArePreservedWhenSavingTheirOutcomesFails() async throws {
        for result in [OnchainSendResult.rejected(txid: txid, reason: "non-final"), .unknown(txid: txid)] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: result)
            node.onSend = { store.failSave = true }
            let returned = try await send(service, node: node, isMaxAmount: true)
            XCTAssertEqual(returned, result)
            store.failSave = false
            let current = try await service.unresolvedAttempt(walletId: OnchainSendAttemptService.walletId(index: 0))
            XCTAssertEqual(current?.txid, txid)
            XCTAssertEqual(store.snapshot().first?.status, .pending)
            do { _ = try await send(service, node: node); XCTFail("In-memory outcome allowed new send") } catch {}
            XCTAssertEqual(node.calls, 1)
        }
    }

    func testCancellationSpendsTheExactOriginalInputsToThisWalletAndKeepsTheGuard() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let cancelTxid = prepareCancellationReceipt(sender)
        var approved = false
        var authorized = false

        let result = try await service.cancelOriginalPayment(
            using: sender, context: pendingContext(original), satsPerVbyte: 5,
            approvePrepared: { prepared in
                XCTAssertEqual(prepared.txid, cancelTxid)
                XCTAssertEqual(prepared.recipientAmountSats, UInt64(Env.dustLimit))
                XCTAssertEqual(prepared.inputs, original.recoveryContext?.inputs)
                XCTAssertEqual(sender.broadcasts, 1, "Nothing is dispatched before the fee is approved")
                approved = true
            },
            authorize: {
                XCTAssertTrue(approved)
                authorized = true
            }
        )

        XCTAssertEqual(result, .accepted(txid: cancelTxid))
        XCTAssertTrue(authorized)
        XCTAssertEqual(sender.lastAddress, sender.ownAddress)
        XCTAssertEqual(sender.lastAmount, UInt64(Env.dustLimit))
        XCTAssertEqual(sender.lastFeeRate, 5)
        XCTAssertEqual(sender.lastMax, false)
        XCTAssertEqual(sender.lastInputs, original.recoveryContext?.inputs)
        XCTAssertEqual(sender.broadcasts, 2)
        let held = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(held.id, original.id)
        XCTAssertEqual(held.recoveryContext, original.recoveryContext)
        XCTAssertEqual(held.cancellationTxid, cancelTxid)
        XCTAssertTrue(held.blocksNewSend, "The guard stays until the cancellation is final")
        do {
            _ = try await service.admit(walletId: original.walletId, requestId: nil, orderId: nil,
                                        address: "bcrt1qnext", amountSats: 1000, isMaxAmount: false)
            XCTFail("A sent cancellation must not release the guard")
        } catch OnchainSendAttemptError.blocked {}
    }

    func testCancellationNeverDispatchesChangedInputsTheRecipientACandidateOrAnAcceptedPayment() async throws {
        for refusal in 0 ..< 11 {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            let original = try await dispatchedOriginal(service, store: store, sender: sender)
            let originalTxid = try XCTUnwrap(original.txid)
            _ = prepareCancellationReceipt(sender)
            var context = pendingContext(original)
            var feeRate: UInt32 = 5
            var authorize: () async throws -> Void = {}
            switch refusal {
            case 0: sender.inputs = [OnchainSendInput(txid: String(repeating: "aa", count: 32), vout: 1)]
            case 1: sender.inputs.append(OnchainSendInput(txid: String(repeating: "aa", count: 32), vout: 1))
            case 2: sender.ownAddress = original.address.uppercased()
            case 3: sender.txid = originalTxid
            case 4: sender.amount += 1
            case 5: sender.currentWalletIndex = 1
            case 6: context = OnchainSendPendingContext(attemptId: UUID(), walletId: original.walletId, txid: original.txid)
            case 7: feeRate = 1000
            case 8: authorize = { _ = try await service.observeConfirmedTransaction(txid: originalTxid) }
            case 9: _ = try await service.observeConfirmedTransaction(txid: originalTxid)
            default: authorize = { throw CancellationError() }
            }
            do {
                _ = try await service.cancelOriginalPayment(using: sender, context: context, satsPerVbyte: feeRate, authorize: authorize)
                XCTFail("Refused cancellation \(refusal) was dispatched")
            } catch {}
            XCTAssertEqual(sender.broadcasts, 1, "Refused cancellation \(refusal) reached the network")
            XCTAssertEqual(store.snapshot().first?.id, original.id)
            XCTAssertEqual(store.snapshot().first?.recoveryContext, original.recoveryContext)
            XCTAssertEqual(store.snapshot().first?.blocksNewSend, true)
        }
    }

    func testFinalNonPaymentSpendOfAnOriginalInputReleasesAnUnresolvableRequestOrOrderGuard() async throws {
        let request = PaykitPaymentRequest.ID(paymentRequestId: "expired-shop", counterparty: "merchant", billingPeriodStartsAt: nil)
        for orderBound in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            let original = try await dispatchedOriginal(
                service, store: store, sender: sender, requestId: orderBound ? nil : request, orderId: orderBound ? "expired-order" : nil
            )
            sender.spends = try [finalCancellation(of: original)]
            let released = expectation(description: "Pending learns of the release")
            let subscription = OnchainSendAttemptService.cancellationReleasePublisher.sink { attemptId in
                if attemptId == original.id {
                    released.fulfill()
                }
            }
            defer { subscription.cancel() }
            var removedProof: OnchainSendAttempt?

            let result = try await service.settleFromWallet(using: sender) { attempt in
                removedProof = attempt
                XCTAssertEqual(store.snapshot(), [attempt], "The proof goes before the guard")
                return true
            }

            XCTAssertEqual(result, .cancelled(original))
            XCTAssertEqual(removedProof, original)
            XCTAssertTrue(store.snapshot().isEmpty)
            await fulfillment(of: [released], timeout: 1)
            _ = try await service.admit(walletId: original.walletId, requestId: nil, orderId: nil,
                                        address: "bcrt1qnext", amountSats: 1000, isMaxAmount: false)
        }
    }

    func testSpendsACandidateCouldStillBeatOrThatMayPayTheRecipientNeverReleaseTheGuard() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let originalTxid = try XCTUnwrap(original.txid)
        let final = try finalCancellation(of: original)
        let keptSpends = [
            OnchainInputSpend(txid: final.txid, inputs: final.inputs, outputAddresses: final.outputAddresses, isFinal: false),
            OnchainInputSpend(txid: final.txid, inputs: final.inputs, outputAddresses: [original.address.uppercased(), "bcrt1qchange"],
                              isFinal: true),
            OnchainInputSpend(txid: final.txid, inputs: final.inputs, outputAddresses: [nil, "bcrt1qchange"], isFinal: true),
            OnchainInputSpend(txid: final.txid, inputs: final.inputs, outputAddresses: [], isFinal: true),
            OnchainInputSpend(txid: final.txid, inputs: [OnchainSendInput(txid: String(repeating: "33", count: 32), vout: 0)],
                              outputAddresses: final.outputAddresses, isFinal: true),
        ]
        for spend in keptSpends {
            sender.spends = [spend]
            let released = try await service.settleFromWallet(using: sender) { _ in
                XCTFail("The original proof must stay")
                return true
            }
            XCTAssertNil(released)
            XCTAssertEqual(store.snapshot(), [original])
        }

        sender.spends = [final]
        sender.currentWalletIndex = 1
        let otherWallet = try await service.settleFromWallet(using: sender) { _ in true }
        XCTAssertNil(otherWallet)
        sender.currentWalletIndex = 0
        let proofKept = try await service.settleFromWallet(using: sender) { _ in false }
        XCTAssertNil(proofKept)
        XCTAssertEqual(store.snapshot(), [original])
        sender.spendsError = NodeError.NotRunning(message: "lookup failed")
        do {
            _ = try await service.settleFromWallet(using: sender) { _ in true }
            XCTFail("A failed lookup must not read as no cancellation")
        } catch {}
        XCTAssertEqual(store.snapshot(), [original])

        sender.spendsError = nil
        // A final candidate is the winner, not a cancellation.
        sender.spends = [OnchainInputSpend(txid: originalTxid.uppercased(), inputs: final.inputs, outputAddresses: final.outputAddresses,
                                           isFinal: true)]
        let confirmed = try await service.settleFromWallet(using: sender) { _ in
            XCTFail("The original proof must stay")
            return true
        }
        XCTAssertEqual(confirmed, .confirmed(txid: originalTxid))
        let accepted = try await service.settleFromWallet(using: sender) { _ in true }
        XCTAssertNil(accepted)
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
        XCTAssertEqual(store.snapshot().first?.blocksNewSend, true)
    }

    func testAFinalUnrecordedPaymentToTheRecipientSettlesAsItsWinner() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let request = PaykitPaymentRequest.ID(paymentRequestId: "restored-shop", counterparty: "merchant", billingPeriodStartsAt: nil)
        let original = try await dispatchedOriginal(service, store: store, sender: sender, requestId: request)
        let inputs = try XCTUnwrap(original.recoveryContext?.inputs)
        // A fee bump of the original that a restore lost: the same coins, the recipient paid in full, at twice the fee.
        let bump = String(repeating: "cc", count: 32)
        func payment(inputs: [OnchainSendInput], paidSats: UInt64, isFinal: Bool = true, feeSats: UInt64? = 1000) -> OnchainInputSpend {
            OnchainInputSpend(txid: bump.uppercased(), inputs: inputs, outputAddresses: [original.address, "bcrt1qchange"], isFinal: isFinal,
                              outputValues: [paidSats, 700], feeSats: feeSats, satsPerVbyte: feeSats.map { _ in 7 })
        }
        let extra = OnchainSendInput(txid: String(repeating: "33", count: 32), vout: 1)
        // The amount reached only across two outputs to the recipient, which no candidate pays.
        let split = OnchainInputSpend(txid: bump, inputs: inputs, outputAddresses: [original.address, original.address.uppercased()],
                                      isFinal: true, outputValues: [original.amountSats - 1, 1], feeSats: 1000, satsPerVbyte: 7)
        for kept in [
            payment(inputs: inputs, paidSats: original.amountSats, isFinal: false),
            payment(inputs: inputs, paidSats: original.amountSats - 1),
            payment(inputs: inputs + [extra], paidSats: original.amountSats),
            payment(inputs: [extra], paidSats: original.amountSats),
            split,
            // A fee the wallet cannot work out exactly is never recorded as the payment's.
            payment(inputs: inputs, paidSats: original.amountSats, feeSats: nil),
        ] {
            sender.spends = [kept]
            let settled = try await service.settleFromWallet(using: sender) { _ in
                XCTFail("The original proof must stay")
                return true
            }
            XCTAssertNil(settled)
            XCTAssertEqual(store.snapshot(), [original])
        }

        sender.spends = [payment(inputs: inputs, paidSats: original.amountSats)]
        let settled = try await service.settleFromWallet(using: sender) { _ in
            XCTFail("A payment is settled, not cancelled")
            return true
        }

        XCTAssertEqual(settled, .confirmed(txid: bump))
        let winner = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(winner.status, .accepted)
        XCTAssertEqual(winner.txid, bump)
        XCTAssertEqual(winner.recoveryContext?.candidateFeeSats?[bump], 1000)
        XCTAssertEqual(winner.recoveryContext?.feeRate(for: bump), 7, "The rate its own exact fee pays")
    }

    func testACancellationMustOutbidTheWholeFeeOfARecordedRelease() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let request = PaykitPaymentRequest.ID(paymentRequestId: "expired-shop", counterparty: "merchant", billingPeriodStartsAt: nil)
        let original = try await dispatchedOriginal(service, store: store, sender: sender, requestId: request)
        let approved = try await service.approveRelease(original)
        // The release added a wallet coin, so its fee is above what a cancellation over the original's coins pays at its rate.
        let releasing = try await service.recordRelease(approved, txid: String(repeating: "77", count: 32), feeRate: 9, feeSats: 2000)
        let cancelTxid = prepareCancellationReceipt(sender)
        let broadcasts = sender.broadcasts
        // A cancellation of 141 vB.
        sender.onPrepare = { sender.miningFee = 141 * UInt64(sender.lastFeeRate ?? 0) }
        // 1,974 sats pays less than the release, and 2,115 more but not by its own size, so nodes holding the release refuse
        // both (BIP125 rules 3 and 4).
        for rate: UInt32 in [14, 15] {
            do {
                _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(releasing), satsPerVbyte: rate) {
                    XCTFail("A cancellation below the release is never authorized")
                }
                XCTFail("A cancellation must pay more than the release it replaces, by its own size")
            } catch let error as OnchainCancellationFeeTooLowError {
                XCTAssertEqual(error.requiredFeeSats, 2000)
                XCTAssertEqual(error.feeRate, 15, "Every higher rate pays at least 2,141 sats")
            }
        }
        XCTAssertEqual(sender.broadcasts, broadcasts)

        sender.onPrepare = nil
        sender.miningFee = nil
        do {
            _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(releasing), satsPerVbyte: 16) {
                XCTFail("A cancellation whose fee is unknown is never authorized")
            }
            XCTFail("A cancellation whose fee is unknown cannot be compared with the release")
        } catch OnchainSendAttemptError.retryUnavailable {}
        XCTAssertEqual(sender.broadcasts, broadcasts)

        sender.miningFee = 141 * 16
        let result = try await service.cancelOriginalPayment(using: sender, context: pendingContext(releasing), satsPerVbyte: 16) {}
        XCTAssertEqual(result, .accepted(txid: cancelTxid))
        let held = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(held.cancellationTxid, cancelTxid)
        XCTAssertEqual(held.releaseTxid, releasing.releaseTxid)
        XCTAssertTrue(held.blocksNewSend, "The guard stays until the cancellation is final")
    }

    func testACancellationFeeFloorCoversTheReleaseAndItsOwnSize() {
        // 141 vB at 15 sat/vB pays 2,115 sats, so it is at least 141 vB.
        XCTAssertEqual(OnchainSendAttemptService.cancellationFeeFloor(releaseFeeSats: 2000, feeSats: 2115, satsPerVbyte: 15), 2141)
        // 2,116 sats at 15 sat/vB rounds up to 142 vB.
        XCTAssertEqual(OnchainSendAttemptService.cancellationFeeFloor(releaseFeeSats: 2000, feeSats: 2116, satsPerVbyte: 15), 2142)
        XCTAssertEqual(OnchainSendAttemptService.cancellationFeeFloor(releaseFeeSats: .max, feeSats: 2115, satsPerVbyte: 15), .max)

        // The size is above (fee - 1) / rate, so any rate above the result pays more than the target.
        let highest = OnchainSendAttemptService.highestFeeRate(notAbove: 2140, feeSats: 1974, satsPerVbyte: 14)
        XCTAssertEqual(highest, 15)
        XCTAssertLessThanOrEqual(141 * UInt64(highest), 2140)
        XCTAssertGreaterThan(141 * UInt64(highest + 1), 2140)
        XCTAssertEqual(OnchainSendAttemptService.highestFeeRate(notAbove: 999, feeSats: 1, satsPerVbyte: 1), 999, "A 1 sat fee divides by 1")
        XCTAssertEqual(OnchainSendAttemptService.highestFeeRate(notAbove: .max, feeSats: 2, satsPerVbyte: 2), .max)
    }

    func testCancellationReleaseWaitsForACancellationOrRetryBeingDispatched() async throws {
        for cancelling in [true, false] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            let original = try await dispatchedOriginal(service, store: store, sender: sender)
            let context = pendingContext(original)
            if cancelling {
                _ = prepareCancellationReceipt(sender)
            } else {
                sender.txid = String(repeating: "cd", count: 32)
                sender.result = .unknown(txid: sender.txid)
            }
            let authorization = SuspendedOnchainPreparation()
            let dispatch = Task {
                if cancelling {
                    try await service.cancelOriginalPayment(using: sender, context: context, satsPerVbyte: 5) {
                        await authorization.suspend()
                    }
                } else {
                    try await service.retrySamePayment(using: sender, context: context, satsPerVbyte: 2) { _, _ in
                        await authorization.suspend()
                    }
                }
            }
            await authorization.waitForStart()
            sender.spends = try [finalCancellation(of: original)]

            let released = try await service.settleFromWallet(using: sender) { _ in
                XCTFail("The original proof must stay while a dispatch is in progress")
                return true
            }

            XCTAssertNil(released)
            XCTAssertEqual(store.snapshot().first?.id, original.id)
            XCTAssertEqual(store.snapshot().first?.blocksNewSend, true)
            await authorization.release()
            _ = try await dispatch.value
            XCTAssertEqual(sender.broadcasts, 2)
        }
    }

    func testCancellationLookupPrefersAFinalSpendOfTheOriginalInputs() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let final = try finalCancellation(of: original)
        let confirming = OnchainInputSpend(txid: String(repeating: "dd", count: 32), inputs: final.inputs,
                                           outputAddresses: final.outputAddresses, isFinal: false)
        let candidate = try OnchainInputSpend(txid: XCTUnwrap(original.txid), inputs: final.inputs,
                                              outputAddresses: [original.address], isFinal: true)

        sender.spends = [candidate, confirming, final]
        let preferred = try await service.cancellation(of: original, using: sender)
        XCTAssertEqual(preferred, final)
        sender.spends = [candidate, confirming]
        let pending = try await service.cancellation(of: original, using: sender)
        XCTAssertEqual(pending, confirming)
        sender.spends = [candidate]
        let none = try await service.cancellation(of: original, using: sender)
        XCTAssertNil(none)
        sender.currentWalletIndex = 1
        do {
            _ = try await service.cancellation(of: original, using: sender)
            XCTFail("Another wallet's history says nothing about this attempt")
        } catch {}
    }

    func testInputSpendIsFinalOnlyOnceTheNodeReportsItsConfirmationSucceeded() {
        let guarded = OnchainSendInput(txid: String(repeating: "cd", count: 32), vout: 1)
        let spendTxid = String(repeating: "fe", count: 32)
        let details = LDKNode.TransactionDetails(
            amountSats: -1000,
            inputs: [LDKNode.TxInput(txid: guarded.txid.uppercased(), vout: 1, scriptsig: "", witness: [], sequence: 0)],
            outputs: [
                LDKNode.TxOutput(scriptpubkey: "", scriptpubkeyType: nil, scriptpubkeyAddress: "bcrt1qown", value: 547, n: 0),
                LDKNode.TxOutput(scriptpubkey: "", scriptpubkeyType: nil, scriptpubkeyAddress: nil, value: 0, n: 1),
            ]
        )
        let confirmed = LDKNode.ConfirmationStatus.confirmed(blockHash: String(repeating: "00", count: 32), height: 100, timestamp: 0)
        func payment(_ kind: LDKNode.PaymentKind, _ status: LDKNode.PaymentStatus) -> LDKNode.PaymentDetails {
            LDKNode.PaymentDetails(id: spendTxid, kind: kind, amountMsat: nil, feePaidMsat: nil, direction: .outbound,
                                   status: status, latestUpdateTimestamp: 0)
        }

        let final = OnchainInputSpend(payment: payment(.onchain(txid: spendTxid.uppercased(), status: confirmed), .succeeded),
                                      details: details, guarding: [guarded], previous: { _ in nil })
        XCTAssertEqual(final, OnchainInputSpend(txid: spendTxid, inputs: [guarded], outputAddresses: ["bcrt1qown", nil], isFinal: true,
                                                outputValues: [547, 0]))
        let shallow = OnchainInputSpend(payment: payment(.onchain(txid: spendTxid, status: confirmed), .pending),
                                        details: details, guarding: [guarded], previous: { _ in nil })
        XCTAssertEqual(shallow?.isFinal, false)
        let unconfirmed = OnchainInputSpend(payment: payment(.onchain(txid: spendTxid, status: .unconfirmed), .succeeded),
                                            details: details, guarding: [guarded], previous: { _ in nil })
        XCTAssertEqual(unconfirmed?.isFinal, false)
        XCTAssertNil(OnchainInputSpend(payment: payment(.onchain(txid: spendTxid, status: confirmed), .succeeded), details: details,
                                       guarding: [OnchainSendInput(txid: guarded.txid, vout: 0)], previous: { _ in nil }))
        XCTAssertNil(OnchainInputSpend(
            payment: payment(.bolt11(hash: spendTxid, preimage: nil, secret: nil, description: nil, bolt11: nil), .succeeded),
            details: details, guarding: [guarded], previous: { _ in nil }
        ))
    }

    func testInputSpendFeeIsExactFromTheTransactionsItsCoinsCameFromNeverTheNodesRecordedFee() {
        let guarded = OnchainSendInput(txid: String(repeating: "cd", count: 32), vout: 1)
        let spendTxid = String(repeating: "fe", count: 32)
        // 69 vB: one input without a witness and two outputs with empty scripts.
        let details = LDKNode.TransactionDetails(
            amountSats: -1000,
            inputs: [LDKNode.TxInput(txid: guarded.txid, vout: 1, scriptsig: "", witness: [], sequence: 0)],
            outputs: [
                LDKNode.TxOutput(scriptpubkey: "", scriptpubkeyType: nil, scriptpubkeyAddress: "bcrt1qrecipient", value: 1000, n: 0),
                LDKNode.TxOutput(scriptpubkey: "", scriptpubkeyType: nil, scriptpubkeyAddress: "bcrt1qchange", value: 8860, n: 1),
            ]
        )
        let parent = LDKNode.TransactionDetails(
            amountSats: 10000,
            inputs: [],
            outputs: [
                LDKNode.TxOutput(scriptpubkey: "", scriptpubkeyType: nil, scriptpubkeyAddress: "bcrt1qother", value: 5000, n: 0),
                LDKNode.TxOutput(scriptpubkey: "", scriptpubkeyType: nil, scriptpubkeyAddress: "bcrt1qown", value: 10000, n: 1),
            ]
        )
        let confirmed = LDKNode.ConfirmationStatus.confirmed(blockHash: String(repeating: "00", count: 32), height: 100, timestamp: 0)
        // The node records a zero fee when it cannot work the fee out.
        let payment = LDKNode.PaymentDetails(id: spendTxid, kind: .onchain(txid: spendTxid, status: confirmed), amountMsat: nil,
                                             feePaidMsat: 0, direction: .outbound, status: .succeeded, latestUpdateTimestamp: 0)

        let known = OnchainInputSpend(payment: payment, details: details, guarding: [guarded]) { txid in
            txid == guarded.txid ? parent : nil
        }
        XCTAssertEqual(known?.feeSats, 140)
        XCTAssertEqual(known?.satsPerVbyte, 3, "140 sats over 69 vB, rounded up")

        let unknown = OnchainInputSpend(payment: payment, details: details, guarding: [guarded], previous: { _ in nil })
        XCTAssertNotNil(unknown)
        XCTAssertNil(unknown?.feeSats, "A coin's own transaction is missing, so the fee is unknown, not zero")
        XCTAssertNil(unknown?.satsPerVbyte)
    }

    func testCancellationStateHidesRetriesOnceACancellationMayConfirmButKeepsCancelUntilFinal() {
        let request = PaykitPaymentRequest.ID(paymentRequestId: "shop", counterparty: "merchant", billingPeriodStartsAt: nil)
        let recovery = OnchainSendRecoveryContext(
            inputs: [.init(txid: String(repeating: "cd", count: 32), vout: 0)], satsPerVbyte: 2, paymentIdentity: "payer",
            candidateTxids: [txid], candidateFeeRates: [txid: 3]
        )
        let original = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: request, orderId: nil, address: "bcrt1qrecipient",
                                          amountSats: 1000, isMaxAmount: false, status: .rejected, txid: txid, recoveryContext: recovery)
        let ordinary = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: nil, orderId: nil, address: "bcrt1qrecipient",
                                          amountSats: 1000, isMaxAmount: false, status: .unknown, txid: txid, recoveryContext: recovery)
        var accepted = original
        accepted.status = .accepted
        let cancelTxid = String(repeating: "fe", count: 32)

        var state = OnchainCancellationState()
        XCTAssertTrue(state.canRetry(original))
        XCTAssertTrue(state.canRetryWithoutChecking(original))
        XCTAssertFalse(state.canRetryWithoutChecking(ordinary), "Only a payment request can be retried without checking")
        XCTAssertTrue(state.canCancel(original))
        XCTAssertTrue(state.canCancel(ordinary))
        XCTAssertFalse(state.canCancel(accepted))
        XCTAssertEqual(state.suggestedFeeRate(cancelling: original), 4)
        XCTAssertEqual(state.failureMessage, t("wallet__onchain_cancel_error"))

        let refusal = state.record(.rejected(txid: cancelTxid, reason: "min relay fee not met"), feeRate: 7)
        XCTAssertEqual(refusal, t("wallet__onchain_cancel_error"))
        XCTAssertTrue(state.canRetry(original), "A refused cancellation never reached the network")
        XCTAssertEqual(state.suggestedFeeRate(cancelling: original), 8)
        XCTAssertEqual(state.failureMessage, t("wallet__onchain_cancel_error"))

        XCTAssertNil(state.record(.accepted(txid: cancelTxid), feeRate: 9))
        XCTAssertEqual(state.txid, cancelTxid)
        XCTAssertFalse(state.canRetry(original))
        XCTAssertFalse(state.canRetryWithoutChecking(original))
        XCTAssertTrue(state.canCancel(original), "A cancellation that drops out must stay replaceable")
        XCTAssertEqual(state.suggestedFeeRate(cancelling: original), 10)
        XCTAssertEqual(state.failureMessage, t("wallet__onchain_cancel_pending_error"))
        let recancel = state.record(.rejected(txid: String(repeating: "fd", count: 32), reason: "insufficient fee"), feeRate: 10)
        XCTAssertEqual(recancel, t("wallet__onchain_cancel_pending_error"), "The accepted cancellation still holds the inputs")
        XCTAssertEqual(state.txid, cancelTxid)

        state.found(OnchainInputSpend(txid: cancelTxid, inputs: recovery.inputs, outputAddresses: ["bcrt1qown"], isFinal: true))
        XCTAssertFalse(state.canCancel(original), "A final cancellation only awaits its release")
        XCTAssertFalse(state.canRetry(original))

        var unknown = OnchainCancellationState()
        XCTAssertNil(unknown.record(.unknown(txid: cancelTxid), feeRate: 5), "A cancellation that may have been relayed shows as sent")
        XCTAssertNil(unknown.txid)
        XCTAssertFalse(unknown.canRetry(original), "An unknown cancellation may have been relayed")
        XCTAssertTrue(unknown.canCancel(original))
        let afterUnknown = unknown.record(.rejected(txid: String(repeating: "fd", count: 32), reason: "insufficient fee"), feeRate: 6)
        XCTAssertEqual(afterUnknown, t("wallet__onchain_cancel_pending_error"), "The unknown cancellation may hold the inputs")

        var reopened = OnchainCancellationState()
        reopened.found(OnchainInputSpend(txid: cancelTxid, inputs: recovery.inputs, outputAddresses: ["bcrt1qown"], isFinal: false))
        XCTAssertFalse(reopened.canRetry(original))
        XCTAssertFalse(reopened.canCancel(original), "The wallet cannot build another spend of the coins it holds spent")
        XCTAssertTrue(reopened.canSpeedUp(original))
        XCTAssertEqual(reopened.failureMessage, t("wallet__onchain_cancel_pending_error"))

        // A recorded release of an expired payment holds the original as a sent cancellation, before the wallet knows it.
        var releasing = original
        releasing.releaseTxid = String(repeating: "77", count: 32)
        releasing.releaseFeeRate = 20
        var releaseRecorded = OnchainCancellationState()
        XCTAssertTrue(releaseRecorded.canRetry(original), "No release was recorded")
        XCTAssertFalse(releaseRecorded.canRetry(releasing))
        XCTAssertFalse(releaseRecorded.canRetryWithoutChecking(releasing))
        XCTAssertTrue(releaseRecorded.canCancel(releasing))
        XCTAssertEqual(releaseRecorded.suggestedFeeRate(cancelling: releasing), 21, "A Cancel payment outbids the release's rate")
        XCTAssertEqual(releaseRecorded.failureMessage(for: releasing), t("wallet__onchain_cancel_pending_error"))

        // A Cancel payment refused for paying too little beside the release suggests a rate that outbids it next.
        releaseRecorded.outbid(rate: 25)
        XCTAssertEqual(releaseRecorded.suggestedFeeRate(cancelling: releasing), 26)
        releaseRecorded.outbid(rate: 22)
        XCTAssertEqual(releaseRecorded.suggestedFeeRate(cancelling: releasing), 26, "A lower rate never lowers the suggestion")
    }

    func testCancellationStateOffersTheReleaseOnlyWithoutAnotherCancellation() {
        let request = PaykitPaymentRequest.ID(paymentRequestId: "expired-shop", counterparty: "merchant", billingPeriodStartsAt: nil)
        let recovery = OnchainSendRecoveryContext(
            inputs: [.init(txid: String(repeating: "cd", count: 32), vout: 0)], satsPerVbyte: 2, paymentIdentity: "payer",
            candidateTxids: [txid]
        )
        let original = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: request, orderId: nil, address: "bcrt1qrecipient",
                                          amountSats: 1000, isMaxAmount: false, status: .rejected, txid: txid, recoveryContext: recovery)
        var releasing = original
        releasing.releaseTxid = String(repeating: "77", count: 32)
        let cancellation = OnchainInputSpend(txid: String(repeating: "fe", count: 32), inputs: recovery.inputs,
                                             outputAddresses: ["bcrt1qown"], isFinal: false)

        XCTAssertTrue(OnchainCancellationState().canAbandon(original))
        XCTAssertFalse(OnchainCancellationState().canAbandon(releasing), "A second release is never sent")

        var cancelled = original
        cancelled.cancellationTxid = String(repeating: "fd", count: 32)
        XCTAssertFalse(OnchainCancellationState().canAbandon(cancelled), "A recorded Cancel payment may have reached the network")

        var found = OnchainCancellationState()
        found.found(cancellation)
        XCTAssertFalse(found.canAbandon(original), "The wallet holds a cancellation")

        var unknown = OnchainCancellationState()
        _ = unknown.record(.unknown(txid: cancellation.txid), feeRate: 5)
        XCTAssertFalse(unknown.canAbandon(original), "A Cancel payment may have been relayed")

        // A Cancel payment that failed before it was sent shows what the wallet holds: the release spends the same coins, so it
        // is reported as an earlier cancellation still pending, and nothing else is offered over it.
        var failedCancel = OnchainCancellationState()
        XCTAssertEqual(failedCancel.failureMessage(for: original), t("wallet__onchain_cancel_error"))
        XCTAssertEqual(failedCancel.failureMessage(for: releasing), t("wallet__onchain_cancel_pending_error"))
        failedCancel.found(cancellation)
        XCTAssertEqual(failedCancel.txid, cancellation.txid)
        XCTAssertEqual(failedCancel.failureMessage(for: original), t("wallet__onchain_cancel_pending_error"))
        XCTAssertFalse(failedCancel.canAbandon(original))
        XCTAssertFalse(failedCancel.canRetry(original))
        XCTAssertTrue(failedCancel.canSpeedUp(original))
    }

    func testRetryWithoutCheckingIsOfferedOnlyForAPaymentRequest() {
        let recovery = OnchainSendRecoveryContext(
            inputs: [.init(txid: String(repeating: "cd", count: 32), vout: 0)], satsPerVbyte: 2, paymentIdentity: nil, candidateTxids: [txid]
        )
        let orderBound = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: nil, orderId: "order", address: "bcrt1qorder",
                                            amountSats: 1000, isMaxAmount: false, status: .rejected, txid: txid, recoveryContext: recovery)
        XCTAssertTrue(OnchainCancellationState().canCancel(orderBound))
        XCTAssertFalse(OnchainCancellationState().canRetryWithoutChecking(orderBound), "A Blocktank order is never paid again")
    }

    func testRetryWithoutCheckingSkipsReauthorizationButRefusesAnUnauthorizedRequestBeforeDispatch() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let request = try paymentRequest()
        let original = try await dispatchedOriginal(service, store: store, sender: sender, requestId: request.id)
        let context = pendingContext(original)
        sender.txid = String(repeating: "cd", count: 32)
        sender.result = .accepted(txid: sender.txid)
        var reauthorized = false

        do {
            _ = try await service.retrySamePayment(using: sender, context: context, satsPerVbyte: 2) { attempt, _ in
                try await SendPendingScreen.authorizeOriginalRetry(
                    attempt, reauthorize: true,
                    reauthorizeOriginal: { _ in
                        reauthorized = true
                        throw PaykitPaymentRequestError.requestUnavailable
                    },
                    authorizeUnchecked: { _ in XCTFail("A checked retry re-authorizes the request instead") }
                )
            }
            XCTFail("An expired request must refuse a checked retry")
        } catch PaykitPaymentRequestError.requestUnavailable {}
        XCTAssertTrue(reauthorized)

        for refusal: Error in [OnchainOriginalPaidError(), PaykitPaymentRequestError.requestUnavailable] {
            do {
                _ = try await service.retrySamePayment(using: sender, context: context, satsPerVbyte: 2) { attempt, _ in
                    try await SendPendingScreen.authorizeOriginalRetry(
                        attempt, reauthorize: false,
                        reauthorizeOriginal: { _ in XCTFail("Retry without checking must not re-authorize the request") },
                        authorizeUnchecked: { _ in throw refusal }
                    )
                }
                XCTFail("A request that is paid or cannot be read must not be paid again")
            } catch {}
        }
        XCTAssertEqual(sender.broadcasts, 1)
        XCTAssertEqual(store.snapshot().first?.status, original.status)
        XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateTxids, original.recoveryContext?.candidateTxids)

        var checked = false
        let result = try await service.retrySamePayment(using: sender, context: context, satsPerVbyte: 2) { attempt, _ in
            try await SendPendingScreen.authorizeOriginalRetry(
                attempt, reauthorize: false,
                reauthorizeOriginal: { _ in XCTFail("Retry without checking must not re-authorize the request") },
                authorizeUnchecked: { _ in checked = true }
            )
        }
        XCTAssertTrue(checked)
        XCTAssertEqual(result, .accepted(txid: sender.txid))
        XCTAssertEqual(sender.broadcasts, 2)
    }

    func testARecordedReleaseOrCancellationRefusesEveryRetry() async throws {
        let request = PaykitPaymentRequest.ID(paymentRequestId: "expired-shop", counterparty: "merchant", billingPeriodStartsAt: nil)
        for recorded in ["release", "cancellation"] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            let original = try await dispatchedOriginal(service, store: store, sender: sender, requestId: request)
            let held: OnchainSendAttempt
            if recorded == "release" {
                let approved = try await service.approveRelease(original)
                held = try await service.recordRelease(approved, txid: String(repeating: "77", count: 32), feeRate: 9, feeSats: 1500)
            } else {
                _ = prepareCancellationReceipt(sender)
                sender.result = .unknown(txid: sender.txid)
                _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: 5) {}
                held = try XCTUnwrap(store.snapshot().first)
            }
            XCTAssertTrue(held.mayHaveRelayedCancellation)
            sender.txid = String(repeating: "cd", count: 32)
            sender.amount = original.amountSats
            sender.result = .accepted(txid: sender.txid)
            let broadcasts = sender.broadcasts
            do {
                _ = try await service.retrySamePayment(using: sender, context: pendingContext(held), satsPerVbyte: 3) { _, _ in
                    XCTFail("A retry beside a \(recorded) that may confirm is never authorized")
                }
                XCTFail("A retry beside a recorded \(recorded) must be refused")
            } catch OnchainSendAttemptError.unresolved {}
            XCTAssertEqual(sender.broadcasts, broadcasts, "Nothing went out beside the recorded \(recorded)")
            XCTAssertEqual(store.snapshot(), [held])
        }
    }

    func testACancellationIsSavedBeforeItIsBroadcastAndKeptUnlessRefused() async throws {
        for result in ["accepted", "unknown", "rejected", "notSubmitted"] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            let original = try await dispatchedOriginal(service, store: store, sender: sender)
            let cancelTxid = prepareCancellationReceipt(sender)
            sender.miningFee = 700
            var savedBeforeBroadcast: OnchainSendAttempt?
            sender.onBroadcast = {
                savedBeforeBroadcast = store.snapshot().first
                if result == "notSubmitted" {
                    throw PreparedOnchainSendNotSubmitted(underlying: NodeError.NotRunning(message: "stopped"))
                }
            }
            sender.result = switch result {
            case "accepted": .accepted(txid: cancelTxid)
            case "unknown": .unknown(txid: cancelTxid)
            default: .rejected(txid: cancelTxid, reason: "insufficient fee")
            }

            _ = try? await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: 5) {}

            XCTAssertEqual(savedBeforeBroadcast?.cancellationTxid, cancelTxid, "Saved before \(result) broadcast")
            XCTAssertEqual(savedBeforeBroadcast?.cancellationFeeRate, 5)
            XCTAssertEqual(savedBeforeBroadcast?.cancellationFeeSats, 700)
            let after = try XCTUnwrap(store.snapshot().first)
            XCTAssertEqual(after.id, original.id)
            XCTAssertTrue(after.blocksNewSend)
            if result == "accepted" || result == "unknown" {
                XCTAssertEqual(after.cancellationTxid, cancelTxid, "A \(result) cancellation may confirm")
            } else {
                XCTAssertEqual(after, original, "A \(result) cancellation never reached the network")
            }
        }
    }

    func testARefusedReplacementKeepsTheEarlierCancellation() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let firstTxid = prepareCancellationReceipt(sender)
        sender.miningFee = 700
        _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: 5) {}
        let first = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(first.cancellationTxid, firstTxid)

        sender.txid = String(repeating: "fd", count: 32)
        sender.miningFee = 900
        sender.result = .rejected(txid: sender.txid, reason: "insufficient fee")
        _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(first), satsPerVbyte: 7) {}

        XCTAssertEqual(store.snapshot(), [first], "The refused replacement leaves the earlier cancellation recorded")
    }

    func testACancellationMustOutbidTheHighestCandidateAndTheRecordedCancellation() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        // A large candidate: 2,000 sats at 2 sat/vB, so a small cancellation needs more than its rate to pay more in all.
        sender.miningFee = 2000
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        XCTAssertEqual(original.recoveryContext?.candidateFeeSats?.values.max(), 2000)
        _ = prepareCancellationReceipt(sender)
        // A cancellation of 110 vB.
        sender.onPrepare = { sender.miningFee = 110 * UInt64(sender.lastFeeRate ?? 0) }
        let broadcasts = sender.broadcasts
        for rate: UInt32 in [5, 18] {
            do {
                _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: rate) {
                    XCTFail("A cancellation below the candidate's fee is never authorized")
                }
                XCTFail("A cancellation must pay more than the candidate it replaces, by its own size (\(rate) sat/vB)")
            } catch let error as OnchainCancellationFeeTooLowError {
                XCTAssertEqual(error.requiredFeeSats, 2000)
                XCTAssertEqual(error.feeRate, 19, "Every higher rate pays at least 2,110 sats")
            }
        }
        XCTAssertEqual(sender.broadcasts, broadcasts)

        _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: 20) {}
        let held = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(held.cancellationFeeRate, 20)
        XCTAssertEqual(held.cancellationFeeSats, 2200)

        // A replacement must also pay a higher rate than the cancellation it replaces, even when it pays more in all.
        sender.txid = String(repeating: "fd", count: 32)
        sender.result = .accepted(txid: sender.txid)
        sender.onPrepare = { sender.miningFee = 400 * UInt64(sender.lastFeeRate ?? 0) }
        do {
            _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(held), satsPerVbyte: 20) {
                XCTFail("A replacement at the same rate is never authorized")
            }
            XCTFail("A replacement must outbid the recorded cancellation's rate")
        } catch let error as OnchainCancellationFeeTooLowError {
            XCTAssertEqual(error.feeRate, 20)
        }
        XCTAssertEqual(sender.broadcasts, broadcasts + 1)
    }

    func testAHeldCancellationIsSpedUpByReplacingItAtAHigherRate() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let context = pendingContext(original)
        do {
            _ = try await service.speedUpCancellation(using: sender, context: context, satsPerVbyte: 9) {}
            XCTFail("Nothing held by the wallet can be sped up")
        } catch OnchainSendAttemptError.unresolved {}

        let cancelTxid = prepareCancellationReceipt(sender)
        _ = try await service.cancelOriginalPayment(using: sender, context: context, satsPerVbyte: 5) {}
        let held = try XCTUnwrap(store.snapshot().first)
        sender.spends = try [OnchainInputSpend(txid: cancelTxid, inputs: XCTUnwrap(original.recoveryContext?.inputs),
                                               outputAddresses: ["bcrt1qown", "bcrt1qchange"], isFinal: false,
                                               outputValues: [546, 700], feeSats: 600, satsPerVbyte: 5)]
        for rate: UInt32 in [5, 1000] {
            do {
                _ = try await service.speedUpCancellation(using: sender, context: context, satsPerVbyte: rate) {
                    XCTFail("A bump at \(rate) sat/vB is never authorized")
                }
                XCTFail("A bump must pay a higher rate than the held cancellation, up to 999 sat/vB")
            } catch {}
        }
        XCTAssertTrue(sender.bumps.isEmpty)

        var authorized = false
        let bumped = try await service.speedUpCancellation(using: sender, context: context, satsPerVbyte: 12) {
            XCTAssertTrue(sender.bumps.isEmpty, "Nothing is sent before authorization")
            authorized = true
        }

        XCTAssertTrue(authorized)
        XCTAssertEqual(sender.bumps.map(\.txid), [cancelTxid])
        XCTAssertEqual(sender.bumps.map(\.satsPerVbyte), [12])
        XCTAssertEqual(bumped, sender.bumpedTxid)
        let after = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(after.cancellationTxid, sender.bumpedTxid)
        XCTAssertEqual(after.cancellationFeeRate, 12)
        XCTAssertEqual(after.id, held.id)
        XCTAssertTrue(after.blocksNewSend, "The guard stays until a cancellation is final")
    }

    func testASpedUpCancellationThatCannotBeSavedSaysSoAndKeepsTheEarlierOne() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let cancelTxid = prepareCancellationReceipt(sender)
        _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: 5) {}
        let held = try XCTUnwrap(store.snapshot().first)
        sender.spends = try [OnchainInputSpend(txid: cancelTxid, inputs: XCTUnwrap(original.recoveryContext?.inputs),
                                               outputAddresses: ["bcrt1qown", "bcrt1qchange"], isFinal: false, satsPerVbyte: 5)]

        do {
            _ = try await service.speedUpCancellation(using: sender, context: pendingContext(original), satsPerVbyte: 12) {
                store.failSave = true
            }
            XCTFail("A bump that could not be saved must say so")
        } catch is OnchainCancellationNotRecordedError {}

        XCTAssertEqual(sender.bumps.count, 1, "The bump itself was sent")
        store.failSave = false
        XCTAssertEqual(store.snapshot(), [held], "The earlier cancellation stays recorded")
    }

    func testAHeldCancellationsExactFeeIsSavedOnceTheWalletHoldsIt() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let cancelTxid = prepareCancellationReceipt(sender)
        let before = UInt64(Date().timeIntervalSince1970)
        _ = try await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: 5) {}
        let cancelled = try XCTUnwrap(store.snapshot().first)
        XCTAssertGreaterThanOrEqual(cancelled.lastCancellationSentAt ?? 0, before)
        let inputs = try XCTUnwrap(original.recoveryContext?.inputs)
        sender.spends = [OnchainInputSpend(txid: cancelTxid, inputs: inputs, outputAddresses: ["bcrt1qown", "bcrt1qchange"],
                                           isFinal: false, satsPerVbyte: 5)]
        _ = try await service.speedUpCancellation(using: sender, context: pendingContext(original), satsPerVbyte: 12) {}
        let sped = try XCTUnwrap(store.snapshot().first)
        XCTAssertNil(sped.cancellationFeeSats, "ldk-node does not report the bump's fee")

        // Another spend, or one whose fee is unknown, is not the recorded one.
        for other in [
            OnchainInputSpend(txid: cancelTxid, inputs: inputs, outputAddresses: ["bcrt1qown"], isFinal: false, feeSats: 900),
            OnchainInputSpend(txid: sender.bumpedTxid, inputs: inputs, outputAddresses: ["bcrt1qown"], isFinal: false),
        ] {
            try await service.recordHeldCancellationFee(other, attemptId: original.id)
            XCTAssertEqual(store.snapshot(), [sped])
        }
        try await service.recordHeldCancellationFee(
            OnchainInputSpend(txid: sender.bumpedTxid.uppercased(), inputs: inputs, outputAddresses: ["bcrt1qown"], isFinal: false,
                              feeSats: 1500, satsPerVbyte: 13),
            attemptId: original.id
        )
        let recorded = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(recorded.cancellationFeeSats, 1500)
        XCTAssertEqual(recorded.cancellationFeeRate, 13)
        XCTAssertEqual(OnchainSendAttemptService.replacedFee(recorded).feeSats, 1500, "A new Cancel payment outbids the bump's fee")
    }

    func testAConfirmationSeenWhileACancellationIsBroadcastWaitsForItsOutcome() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        let original = try await dispatchedOriginal(service, store: store, sender: sender)
        let originalTxid = try XCTUnwrap(original.txid)
        let cancelTxid = prepareCancellationReceipt(sender)
        let broadcast = AsyncGate()
        let broadcastStarted = expectation(description: "The cancellation is being broadcast")
        sender.onBroadcast = {
            broadcastStarted.fulfill()
            await broadcast.wait()
        }
        let cancel = Task { try await service.cancelOriginalPayment(using: sender, context: pendingContext(original), satsPerVbyte: 5) {} }
        await fulfillment(of: [broadcastStarted], timeout: 2)
        let observed = Task { try await service.observeConfirmedTransaction(txid: originalTxid) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.snapshot().first?.status, .rejected, "The confirmation waits for the broadcast")

        broadcast.open()
        let result = try await cancel.value
        let didObserve = try await observed.value

        XCTAssertEqual(result, .accepted(txid: cancelTxid))
        XCTAssertTrue(didObserve)
        let after = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(after.status, .accepted)
        XCTAssertEqual(after.txid, originalTxid)
        XCTAssertEqual(after.cancellationTxid, cancelTxid)
    }

    func testCancellationStateReadsRecordedCancellationsAndThePendingEstimate() {
        let request = PaykitPaymentRequest.ID(paymentRequestId: "shop", counterparty: "merchant", billingPeriodStartsAt: nil)
        let recovery = OnchainSendRecoveryContext(
            inputs: [.init(txid: String(repeating: "cd", count: 32), vout: 0)], satsPerVbyte: 2, paymentIdentity: "payer",
            candidateTxids: [txid], candidateFeeRates: [txid: 3]
        )
        let original = OnchainSendAttempt(id: UUID(), walletId: walletId, requestId: request, orderId: nil, address: "bcrt1qrecipient",
                                          amountSats: 1000, isMaxAmount: false, status: .rejected, txid: txid, recoveryContext: recovery)
        var cancelled = original
        cancelled.cancellationTxid = String(repeating: "fe", count: 32)
        cancelled.cancellationFeeRate = 30
        var released = original
        released.releaseTxid = String(repeating: "77", count: 32)
        released.releaseFeeRate = 40

        let state = OnchainCancellationState()
        XCTAssertEqual(state.suggestedFeeRate(cancelling: original, normalRate: nil), 4)
        XCTAssertEqual(state.suggestedFeeRate(cancelling: original, normalRate: 25), 25, "A cancellation confirms at least as fast as a normal send")
        for recorded in [cancelled, released] {
            XCTAssertFalse(state.canRetry(recorded), "A recorded cancellation may confirm, as soon as the attempt loads")
            XCTAssertFalse(state.canRetryWithoutChecking(recorded))
            XCTAssertFalse(state.canAbandon(recorded))
            XCTAssertTrue(state.canCancel(recorded))
            XCTAssertEqual(state.failureMessage(for: recorded), t("wallet__onchain_cancel_pending_error"))
        }
        XCTAssertEqual(state.suggestedFeeRate(cancelling: cancelled, normalRate: 25), 31)
        XCTAssertEqual(state.suggestedFeeRate(cancelling: released, normalRate: 25), 41)
        XCTAssertEqual(state.sentTxid(for: cancelled), cancelled.cancellationTxid)
        XCTAssertNil(state.sentTxid(for: original))
        XCTAssertTrue(state.canRetry(original))

        // The first cancellation whose outcome is unknown may have been relayed, so it shows as sent rather than failed.
        var unknown = OnchainCancellationState()
        XCTAssertNil(unknown.record(.unknown(txid: String(repeating: "fe", count: 32)), feeRate: 5))

        // A cancellation the wallet holds unconfirmed is sped up rather than replaced, which the wallet cannot build.
        var held = OnchainCancellationState()
        held.found(OnchainInputSpend(txid: String(repeating: "fe", count: 32), inputs: recovery.inputs, outputAddresses: ["bcrt1qown"],
                                     isFinal: false, satsPerVbyte: 6))
        XCTAssertFalse(held.canCancel(original))
        XCTAssertTrue(held.canSpeedUp(original))
        XCTAssertEqual(held.suggestedSpeedUpRate(normalRate: nil), 7)
        XCTAssertEqual(held.suggestedSpeedUpRate(normalRate: 25), 25)
        XCTAssertFalse(held.isFinalButHeld)

        // A later read that finds nothing drops the held state. After a wallet sync since it was sent, the cancellation may
        // never have reached the network, so a new one can be sent, while retries stay hidden in case it is elsewhere.
        var dropped = held
        dropped.read(nil, syncedSinceSent: false)
        XCTAssertFalse(dropped.canSpeedUp(original))
        XCTAssertTrue(dropped.canCancel(original))
        XCTAssertFalse(dropped.mayNotHaveReachedNetwork)
        dropped.read(nil, syncedSinceSent: true)
        XCTAssertTrue(dropped.mayNotHaveReachedNetwork)
        XCTAssertTrue(dropped.canCancel(original))
        XCTAssertFalse(dropped.canRetry(original), "It may still confirm in another mempool")
        XCTAssertFalse(dropped.canAbandon(original))
        XCTAssertNil(dropped.record(.accepted(txid: String(repeating: "fd", count: 32)), feeRate: 9))
        XCTAssertFalse(dropped.mayNotHaveReachedNetwork, "A new cancellation was just sent")
        var unseen = OnchainCancellationState()
        unseen.read(nil, syncedSinceSent: true)
        XCTAssertTrue(unseen.canCancel(cancelled))
        XCTAssertFalse(unseen.canRetry(cancelled))

        var final = OnchainCancellationState()
        final.found(OnchainInputSpend(txid: String(repeating: "fe", count: 32), inputs: recovery.inputs, outputAddresses: ["bcrt1qown"],
                                      isFinal: true))
        XCTAssertFalse(final.canCancel(original))
        XCTAssertFalse(final.canSpeedUp(original))
        XCTAssertTrue(final.isFinalButHeld, "A final cancellation whose guard is still held says so")
    }

    private func dispatchedOriginal(
        _ service: OnchainSendAttemptService, store: MemoryAttemptStore, sender: PreparedAttemptNodeMock,
        requestId: PaykitPaymentRequest.ID? = nil, orderId: String? = nil
    ) async throws -> OnchainSendAttempt {
        sender.result = .rejected(txid: sender.txid, reason: "min relay fee not met")
        _ = try await service.send(
            using: sender, address: "bcrt1qrecipient", amountSats: sender.amount, satsPerVbyte: 2, utxosToSpend: nil,
            isMaxAmount: false, requestId: requestId, orderId: orderId, paymentIdentity: requestId.map { _ in "payer" }
        )
        let original = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(original.status, .rejected)
        XCTAssertTrue(original.canRetrySamePayment)
        return original
    }

    private func prepareCancellationReceipt(_ sender: PreparedAttemptNodeMock) -> String {
        let cancelTxid = String(repeating: "fe", count: 32)
        sender.txid = cancelTxid
        sender.amount = UInt64(Env.dustLimit)
        // Above every candidate's 500 sats by its own size, as a replacement must be.
        sender.miningFee = 1000
        sender.result = .accepted(txid: cancelTxid)
        return cancelTxid
    }

    private func finalCancellation(of original: OnchainSendAttempt) throws -> OnchainInputSpend {
        try OnchainInputSpend(txid: String(repeating: "fe", count: 32), inputs: XCTUnwrap(original.recoveryContext?.inputs),
                              outputAddresses: ["bcrt1qown", "bcrt1qchange"], isFinal: true)
    }

    private func pendingContext(_ attempt: OnchainSendAttempt) -> OnchainSendPendingContext {
        OnchainSendPendingContext(attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid)
    }

    private func paymentRequest() throws -> PaykitPaymentRequest {
        let record = try PaymentRequestRecord(
            counterparty: "pubky\(String(repeating: "y", count: 52))",
            paymentRequestId: "550e8400-e29b-41d4-a716-446655440000",
            localRole: .payer,
            state: .proposed,
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
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue],
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
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
        return try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
    }

    private func send(
        _ service: OnchainSendAttemptService, node: AttemptNodeMock, orderId: String? = nil, isMaxAmount: Bool = false
    ) async throws -> OnchainSendResult {
        try await service.send(
            using: node, address: "bcrt1qexample", amountSats: 1000,
            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: isMaxAmount, orderId: orderId
        )
    }

    private func admit(_ service: OnchainSendAttemptService) async throws -> UUID {
        try await service.admit(
            walletId: walletId,
            requestId: nil,
            orderId: nil,
            address: "bcrt1qexample",
            amountSats: 1000,
            isMaxAmount: false
        )
    }

    func testRestoredPaymentCanBeCancelledAfterAWipe() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        sender.result = .unknown(txid: sender.txid)
        _ = try await service.send(using: sender, address: "bcrt1qrequest", amountSats: sender.amount, satsPerVbyte: 2,
                                   utxosToSpend: nil, isMaxAmount: false,
                                   requestId: .init(paymentRequestId: "request", counterparty: "payee"), paymentIdentity: "payer")
        let attempt = try XCTUnwrap(store.snapshot().first)
        XCTAssertTrue(attempt.canBeAbandoned)
        let restoredService = OnchainSendAttemptService(store: MemoryAttemptStore())
        try await restoredService.restoreBackup(attempt)
        let restored = try await restoredService.blockingAttempt()
        XCTAssertEqual(restored?.restoredFromBackup, true)
        // The release transaction, not the restore marker, keeps a restored attempt safe to cancel.
        XCTAssertEqual(restored?.canBeAbandoned, true)
    }

    func testRestoreKeepsALocalReleaseApproval() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        sender.result = .unknown(txid: sender.txid)
        _ = try await service.send(using: sender, address: "bcrt1qrequest", amountSats: sender.amount, satsPerVbyte: 2,
                                   utxosToSpend: nil, isMaxAmount: false,
                                   requestId: .init(paymentRequestId: "request", counterparty: "payee"), paymentIdentity: "payer")
        let attempt = try XCTUnwrap(store.snapshot().first)
        let approved = try await service.approveRelease(attempt)
        let releasing = try await service.recordRelease(approved, txid: String(repeating: "77", count: 32), feeRate: 9, feeSats: 1500)
        XCTAssertEqual(releasing.releaseFeeRate, 9)
        XCTAssertEqual(releasing.releaseFeeSats, 1500)
        try await service.restoreBackup(attempt)
        XCTAssertEqual(store.snapshot(), [releasing])
    }

    func testRefusedBlocktankFundingIsReleasedOnceItsReleaseIsFinal() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        sender.result = .rejected(txid: sender.txid, reason: "min relay fee not met")
        _ = try? await service.send(using: sender, address: "bcrt1qfunding", amountSats: sender.amount, satsPerVbyte: 2,
                                    utxosToSpend: nil, isMaxAmount: false, orderId: "order-1")
        let attempt = try XCTUnwrap(store.snapshot().first)
        XCTAssertTrue(attempt.isBlocktankFunding)
        // Retry original is refused while transfers are unavailable, so release is the only exit.
        XCTAssertTrue(attempt.canBeAbandoned)
        let approved = try await service.approveRelease(attempt)
        let releaseTxid = String(repeating: "77", count: 32)
        let releasing = try await service.recordRelease(approved, txid: releaseTxid, feeRate: 9, feeSats: 1500)
        let release = try OnchainInputSpend(txid: releaseTxid, inputs: XCTUnwrap(releasing.recoveryContext?.inputs),
                                            outputAddresses: ["bcrt1qown", "bcrt1qchange"], isFinal: false)
        sender.spends = [release]
        let early = try await service.settleFromWallet(using: sender) { _ in
            XCTFail("A release that is not final keeps the guard")
            return true
        }
        XCTAssertNil(early)
        XCTAssertEqual(store.snapshot(), [releasing])

        sender.spends = [OnchainInputSpend(txid: releaseTxid, inputs: release.inputs, outputAddresses: release.outputAddresses, isFinal: true)]
        let settled = try await service.settleFromWallet(using: sender) { _ in true }
        XCTAssertEqual(settled, .cancelled(releasing))
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testOrdinaryPaymentIsNeverAbandoned() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let sender = PreparedAttemptNodeMock()
        sender.result = .unknown(txid: sender.txid)
        _ = try await service.send(using: sender, address: "bcrt1qordinary", amountSats: sender.amount,
                                   satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
        let attempt = try XCTUnwrap(store.snapshot().first)
        XCTAssertFalse(attempt.canBeAbandoned)
        do {
            _ = try await service.approveRelease(attempt)
            XCTFail("Approved the release of an ordinary payment")
        } catch {}
        XCTAssertEqual(store.snapshot(), [attempt])
    }
}

final class MemoryAttemptStore: OnchainSendAttemptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [OnchainSendAttempt] = []
    var failLoad = false
    var failSave = false

    func load() throws -> [OnchainSendAttempt] {
        lock.lock()
        defer { lock.unlock() }
        if failLoad {
            throw MemoryAttemptStoreError.failed
        }
        return attempts
    }

    func save(_ attempts: [OnchainSendAttempt]) throws {
        lock.lock()
        defer { lock.unlock() }
        if failSave {
            throw MemoryAttemptStoreError.failed
        }
        self.attempts = attempts
    }

    func snapshot() -> [OnchainSendAttempt] {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }
}

private enum MemoryAttemptStoreError: Error {
    case failed
}

final class AttemptNodeMock: OnchainSending {
    var currentWalletIndex = 0
    var dispatchNode: AnyObject = NSObject()
    var onchainDispatchNode: AnyObject? {
        dispatchNode
    }

    var calls = 0
    var result: OnchainSendResult
    var error: Error?
    var onSend: (() async throws -> Void)?

    init(result: OnchainSendResult) {
        self.result = result
    }

    var preparedMiningFeeSats: UInt64?
    var preparedRecipientAmountSats: UInt64?
    var preparationError: Error?
    var onPrepare: (() async throws -> Void)?

    func prepareOnchainSend(address: String, sats: UInt64, satsPerVbyte: UInt32,
                            utxosToSpend: [SpendableUtxo]?, isMaxAmount: Bool,
                            expectedWalletIndex: Int, expectedNode: AnyObject?,
                            paymentDeadline: PaykitPreciseInstant?) async throws -> PreparedOnchainSendDispatch
    {
        try await onPrepare?()
        if let preparationError {
            throw preparationError
        }
        let candidate: String = switch result {
        case let .accepted(txid), let .rejected(txid, _), let .unknown(txid): txid
        }
        return PreparedOnchainSendDispatch(txid: candidate,
                                           inputs: [OnchainSendInput(txid: String(repeating: "ef", count: 32), vout: 0)],
                                           recipientAmountSats: preparedRecipientAmountSats ?? sats, miningFeeSats: preparedMiningFeeSats)
        {
            try await self.send(address: address, sats: sats, satsPerVbyte: satsPerVbyte, utxosToSpend: utxosToSpend,
                                isMaxAmount: isMaxAmount, expectedWalletIndex: expectedWalletIndex, expectedNode: expectedNode)
        }
    }

    func send(address: String, sats: UInt64, satsPerVbyte: UInt32, utxosToSpend: [SpendableUtxo]?,
              isMaxAmount: Bool, expectedWalletIndex: Int?, expectedNode: AnyObject?) async throws -> OnchainSendResult
    {
        calls += 1
        try await onSend?()
        if let error {
            throw error
        }
        return result
    }

    func newAddress() async throws -> String {
        "bcrt1qown"
    }

    func bumpFee(ofTransaction txid: String, satsPerVbyte: UInt32, expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> String
    {
        throw NodeError.NotRunning(message: "Not used")
    }

    func walletSpends(of inputs: [OnchainSendInput], expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> [OnchainInputSpend]
    {
        []
    }
}

final class PreparedAttemptNodeMock: OnchainSending {
    var currentWalletIndex = 0
    let dispatchNode = NSObject()
    var onchainDispatchNode: AnyObject? {
        dispatchNode
    }

    var txid = String(repeating: "ab", count: 32)
    var amount: UInt64 = 1234
    var miningFee: UInt64? = 500
    var inputs = [OnchainSendInput(txid: String(repeating: "ef", count: 32), vout: 0)]
    var preparations = 0
    var broadcasts = 0
    var legacyCalls = 0
    var lastAddress: String?
    var lastAmount: UInt64?
    var lastFeeRate: UInt32?
    var lastMax: Bool?
    var lastInputs: [OnchainSendInput]?
    var onBroadcast: (() async throws -> Void)?
    var onPrepare: (() async throws -> Void)?
    var result: OnchainSendResult?
    var deadlineClock: () -> Date = Date.init
    var onNativeQueueDispatch: (() -> Void)?

    func prepareOnchainSend(address: String, sats: UInt64, satsPerVbyte: UInt32,
                            utxosToSpend: [SpendableUtxo]?, isMaxAmount: Bool,
                            expectedWalletIndex: Int, expectedNode: AnyObject?,
                            paymentDeadline: PaykitPreciseInstant?) async throws -> PreparedOnchainSendDispatch
    {
        preparations += 1
        lastAddress = address
        lastAmount = sats
        lastFeeRate = satsPerVbyte
        lastMax = isMaxAmount
        lastInputs = utxosToSpend?.map { OnchainSendInput(txid: $0.outpoint.txid, vout: $0.outpoint.vout) }
        try await onPrepare?()
        let candidateId = txid
        return PreparedOnchainSendDispatch(txid: candidateId, inputs: inputs, recipientAmountSats: amount, miningFeeSats: miningFee) {
            self.onNativeQueueDispatch?()
            do { try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline, at: self.deadlineClock()) }
            catch { throw PreparedOnchainSendNotSubmitted(underlying: error) }
            self.broadcasts += 1
            try await self.onBroadcast?()
            return self.result ?? .unknown(txid: candidateId)
        }
    }

    func send(address: String, sats: UInt64, satsPerVbyte: UInt32, utxosToSpend: [SpendableUtxo]?, isMaxAmount: Bool,
              expectedWalletIndex: Int?, expectedNode: AnyObject?) async throws -> OnchainSendResult
    {
        legacyCalls += 1
        return .unknown(txid: txid)
    }

    var ownAddress = "bcrt1qown"
    var spends: [OnchainInputSpend] = []
    var spendsError: Error?
    var bumpedTxid = String(repeating: "bb", count: 32)
    var bumps: [(txid: String, satsPerVbyte: UInt32)] = []

    func bumpFee(ofTransaction txid: String, satsPerVbyte: UInt32, expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> String
    {
        guard expectedWalletIndex == currentWalletIndex, expectedNode === dispatchNode else {
            throw NodeError.NotRunning(message: "Wallet changed")
        }
        bumps.append((txid, satsPerVbyte))
        return bumpedTxid
    }

    func newAddress() async throws -> String {
        ownAddress
    }

    func walletSpends(of inputs: [OnchainSendInput], expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> [OnchainInputSpend]
    {
        if let spendsError {
            throw spendsError
        }
        guard expectedWalletIndex == currentWalletIndex, expectedNode === dispatchNode else {
            throw NodeError.NotRunning(message: "Wallet changed")
        }
        return spends
    }
}

private final class CapturingWinningFeeFollowup: OnchainSendLocalFollowupHandling {
    var attempt: OnchainSendAttempt?
    func save(_ attempt: OnchainSendAttempt) async throws -> OnchainActivity {
        self.attempt = attempt
        throw OnchainSendAttemptError.localFollowupNotSaved
    }
}

private actor SuspendedOrdinaryFollowup: OnchainSendLocalFollowupHandling {
    private var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?

    func waitForStart() async {
        if calls > 0 {
            return
        }
        await withCheckedContinuation { started = $0 }
    }

    func save(_ attempt: OnchainSendAttempt) async throws -> OnchainActivity {
        calls += 1
        if calls == 1 {
            started?.resume()
            started = nil
            await withCheckedContinuation { suspended = $0 }
        }
        throw OnchainSendAttemptError.localFollowupNotSaved
    }

    func release() {
        suspended?.resume()
        suspended = nil
    }

    func callCount() -> Int {
        calls
    }
}

private actor SuspendedOnchainPreparation {
    private var hasStarted = false
    private var started: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?

    func waitForStart() async {
        if hasStarted {
            return
        }
        await withCheckedContinuation { started = $0 }
    }

    func suspend() async {
        hasStarted = true
        started?.resume()
        started = nil
        await withCheckedContinuation { suspended = $0 }
    }

    func release() {
        suspended?.resume()
        suspended = nil
    }
}
