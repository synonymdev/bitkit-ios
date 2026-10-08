@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class OnchainSendAttemptServiceTests: XCTestCase {
    private let walletId = "node-0"
    private let txid = String(repeating: "ab", count: 32)

    func testAcceptedConfirmationStaysPendingUntilOriginalFollowupCompletes() async throws {
        let shopRequest = PaykitPaymentRequest.ID(paymentRequestId: "original-shop-order", counterparty: "original-merchant", billingPeriodStartsAt: nil)
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
            let service = OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false })
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
            let result = try await service.retrySamePayment(
                using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid),
                paymentDeadline: deadline, authorize: { _, _ in
                    // Deadline crosses after request authorization while native dispatch awaits its queue.
                    sender.onNativeQueueDispatch = { dispatchTime = deadlineDate.addingTimeInterval(expired ? 0.001 : 0) }
                }
            )
            XCTAssertEqual(sender.broadcasts, expired ? 1 : 2, "An expired successor must never reach native broadcast")
            XCTAssertEqual(result, .unknown(txid: sender.txid))
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
        for amount: UInt64 in [98999, 100001, 99500] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let sender = PreparedAttemptNodeMock()
            sender.amount = amount
            let context = OnchainSendTransferContext(clientBalanceSats: 97000, txTotalSats: 100000,
                                                     preTransferOnchainSats: 100000, originalOrderFeeSats: 99000)
            do {
                _ = try await service.send(using: sender, address: "original", amountSats: 99000,
                                           satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: true,
                                           orderId: "original-order", transferContext: context)
                XCTAssertEqual(amount, 99500)
                XCTAssertEqual(sender.broadcasts, 1)
                XCTAssertEqual(store.snapshot().first?.amountSats, 99500)
                XCTAssertEqual(store.snapshot().first?.transferContext, context)
            } catch {
                XCTAssertNotEqual(amount, 99500, "Valid surplus funding must remain supported")
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
        _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                   satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false,
                                   followupContext: .init(feeSats: 143, feeRate: 1, tags: [], contact: nil, createdAt: 123))
        let original = try XCTUnwrap(store.snapshot().first)
        let originalTxid = try XCTUnwrap(original.txid)
        sender.txid = String(repeating: "cd", count: 32)
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
            _ = try await service.send(using: sender, address: "original", amountSats: sender.amount,
                                       satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
            let original = try XCTUnwrap(store.snapshot().first)
            let originalTxid = try XCTUnwrap(original.txid)
            sender.txid = String(repeating: "cd", count: 32)
            do {
                _ = try await service.retrySamePayment(
                    using: sender, context: .init(attemptId: original.id, walletId: original.walletId, txid: originalTxid),
                    satsPerVbyte: 2, authorize: { _, _ in
                        if walletChanges { sender.currentWalletIndex = 1 }
                        else { throw CancellationError() }
                    }
                )
                XCTFail("Pre-dispatch exit submitted the successor")
            } catch {}
            let retained = try XCTUnwrap(store.snapshot().first)
            XCTAssertEqual(retained.id, original.id)
            XCTAssertEqual(retained.recoveryContext?.inputs, original.recoveryContext?.inputs)
            XCTAssertEqual(retained.recoveryContext?.candidateTxids, [originalTxid])
            XCTAssertNil(retained.recoveryContext?.candidateFeeRates?[sender.txid])
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

    func testUnsignedShopAttemptStillRequiresProofCleanupAfterRestart() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        _ = try await service.admit(
            walletId: WalletScope.default,
            requestId: .init(paymentRequestId: "original-request", counterparty: "payer", billingPeriodStartsAt: nil),
            orderId: nil, address: "bcrt1qexample", amountSats: 1000, isMaxAmount: false
        )
        let restarted = OnchainSendAttemptService(store: store)
        let pending = try await restarted.unresolvedAttempt(walletId: WalletScope.default)
        XCTAssertNotNil(pending, "Shop proof cleanup must precede releasing its guard")
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

    func testPaidOrderStoreProtectsOlderOrderAfterCurrentAttemptIsReplaced() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store, hasPaidOrder: { $0 == "paid-order" })
        let id = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: id)
        try await service.acknowledgeLocalFollowup(txid: txid)
        _ = try await admit(service)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        do {
            _ = try await send(service, node: node, orderId: "paid-order")
            XCTFail("Older paid order was dispatched again")
        } catch let error as OnchainSendAttemptError {
            guard case .duplicate = error else { return XCTFail("Expected paid-order guard") }
        }
        XCTAssertEqual(node.calls, 0)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testActualSendSerializesFixedMaxAndTransferBeforeNodeDispatch() async {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        node.onSend = {
            XCTAssertEqual(store.snapshot().first?.status, .pending)
            await Task.yield()
        }
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 20 {
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
            for await sent in group {
                if sent {
                    count += 1
                }
            }
            return count
        }
        XCTAssertEqual(results, 1)
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
                                           inputs: [OnchainSendInput(txid: String(repeating: "ef", count: 32), vout: 0)], recipientAmountSats: sats)
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
}

final class PreparedAttemptNodeMock: OnchainSending {
    var currentWalletIndex = 0
    let dispatchNode = NSObject()
    var onchainDispatchNode: AnyObject? {
        dispatchNode
    }

    var txid = String(repeating: "ab", count: 32)
    var amount: UInt64 = 1234
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
        return PreparedOnchainSendDispatch(txid: candidateId, inputs: inputs, recipientAmountSats: amount) {
            self.onNativeQueueDispatch?()
            try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline, at: self.deadlineClock())
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
        if calls > 0 { return }
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

    func callCount() -> Int { calls }
}
