@testable import Bitkit
import BitkitCore
import LDKNode
import SwiftUI
import XCTest

/// Regression coverage for the hardware-wallet pending transfer activity. `OnchainActivity.channelId`
/// must hold the LDK `channelId.description` (BOLT id) — it is matched that way by
/// `ChannelDetailsViewModel.findChannel` — never the Blocktank order's short channel id. Storing the
/// SCID there breaks the Connection/channel lookup; the correct BOLT id is set later by
/// `markOnchainActivityAsTransfer` during `syncTransferStates`.
///
/// App types are `Bitkit.`-qualified because some services are also compiled into the test target,
/// so unqualified names would resolve to the duplicate and mismatch `Bitkit.TransferService`.
final class TransferServiceActivityTests: XCTestCase {
    /// Unique per run: `NSTemporaryDirectory()` is shared with every other suite that calls
    /// `initDb`, and `init_db` creates blocktank.db alongside activity.db, which none of them
    /// cleaned up.
    private let testDbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("TransferServiceActivityTests-\(UUID().uuidString)", isDirectory: true).path
    private let activity = Bitkit.CoreService.shared.activity
    private var transferDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        transferDefaults = try makeIsolatedDefaults()
        guardAppDefaults("transfers")
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(atPath: testDbPath, withIntermediateDirectories: true)
        _ = try initDb(basePath: testDbPath)
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        await repointCoreToAppStorage()
        try? FileManager.default.removeItem(atPath: testDbPath)
    }

    private func makeService() -> Bitkit.TransferService {
        Bitkit.TransferService(
            storage: Bitkit.TransferStorage(defaults: transferDefaults),
            lightningService: .shared,
            blocktankService: Bitkit.CoreService.shared.blocktank
        )
    }

    @MainActor
    private func makeWallet(attempts: OnchainSendAttemptService) -> WalletViewModel {
        WalletViewModel(
            transferService: makeService(), sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager(), onchainAttemptService: attempts
        )
    }

    @MainActor
    func testPendingResumeShowsEarlierActivityWithoutSuccessForNewUnsentAmount() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let original = OnchainSendAttemptService(store: store)
        _ = try await original.send(
            using: node, address: "bcrt1qoriginal", amountSats: 4321, satsPerVbyte: 2,
            utxosToSpend: nil, isMaxAmount: false,
            followupContext: OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: [], contact: nil, createdAt: 100)
        )
        let restarted = OnchainSendAttemptService(store: store)
        do {
            _ = try await restarted.send(
                using: node, address: "bcrt1qnew-unsent", amountSats: 9999,
                satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
            )
            XCTFail("New ordinary payment reused old acceptance")
        } catch {}
        let confirmedCallback = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let receivedCallback = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmedCallback
            Bitkit.LightningService.shared.onchainTransactionReceived = receivedCallback
        }
        let wallet = makeWallet(attempts: restarted)
        wallet.sendAmountSats = 9999
        var path: [SendRoute] = []
        let resolutionReady = expectation(description: "Actual Pending task durably finishes original activity")
        let subscription = OnchainSendAttemptService.localResolutionPublisher.sink { resolution in
            if resolution.txid == txid {
                resolutionReady.fulfill()
            }
        }
        defer { subscription.cancel() }
        let view = SendPendingScreen(
            paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: nil,
            routingCacheResetAttempted: false, attemptService: restarted,
            navigationPath: Binding(get: { path }, set: { path = $0 })
        )
        .environmentObject(CurrencyViewModel())
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(ActivityListViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .environmentObject(PubkyProfileManager())
        .environmentObject(SheetViewModel())
        .environmentObject(wallet)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [resolutionReady], timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(path.isEmpty, "Original local resume must not navigate to success for the new unsent payment")
        XCTAssertEqual(wallet.sendAmountSats, 9999, "Original resume overwrote the new payment's amount")
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
        XCTAssertEqual(node.calls, 1)
        let saved = try await activity.getOnchainActivityByTxId(txid: txid)
        XCTAssertEqual(saved?.value, 4321)
    }

    @MainActor
    func testNativeExactObservationFinishesUnknownAndRejectedOrdinaryActivityAndAck() async throws {
        let confirmedCallback = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let receivedCallback = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmedCallback
            Bitkit.LightningService.shared.onchainTransactionReceived = receivedCallback
        }
        for (index, status) in [OnchainSendResult.unknown(txid: String(repeating: "ab", count: 32)),
                                .rejected(txid: String(repeating: "cd", count: 32), reason: "fixture refusal")].enumerated()
        {
            let store = MemoryAttemptStore()
            let txid = index == 0 ? String(repeating: "ab", count: 32) : String(repeating: "cd", count: 32)
            let node = AttemptNodeMock(result: status)
            _ = try await OnchainSendAttemptService(store: store).send(
                using: node, address: "bcrt1qoriginal", amountSats: 4321, satsPerVbyte: 2,
                utxosToSpend: nil, isMaxAmount: false,
                followupContext: OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: [], contact: nil, createdAt: 100)
            )
            let restarted = OnchainSendAttemptService(store: store)
            let wallet = makeWallet(attempts: restarted)
            XCTAssertNotNil(Bitkit.LightningService.shared.onchainTransactionReceived, "App observation callback must be installed")
            await Bitkit.LightningService.shared.onchainTransactionReceived?(String(repeating: "ef", count: 32))
            XCTAssertEqual(store.snapshot().first?.localFollowupComplete, false)
            await Bitkit.LightningService.shared.onchainTransactionReceived?(txid.uppercased())
            XCTAssertEqual(store.snapshot().first?.status, .accepted)
            XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
            let saved = try await activity.getOnchainActivityByTxId(txid: txid)
            XCTAssertEqual(saved?.value, 4321)
            XCTAssertEqual(saved?.fee, 123)
            _ = try await restarted.send(
                using: node, address: "bcrt1qnew", amountSats: 9999, satsPerVbyte: 1,
                utxosToSpend: nil, isMaxAmount: false
            )
            XCTAssertEqual(node.calls, 2, "Exact durable follow-up did not release the guard")
            withExtendedLifetime(wallet) {}
        }
    }

    @MainActor
    func testTransferResumeRetainsOriginalBalanceMetadataAfterTrackingFailure() async throws {
        for isMax in [false, true] {
            transferDefaults.removeObject(forKey: "transfers")
            let store = MemoryAttemptStore()
            let txid = String(repeating: isMax ? "cd" : "ab", count: 32)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            let attempts = OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false })
            let order = IBtOrder.mock()
            let initialTotal = isMax ? UInt64(20000) : order.feeSat + 123
            let vm = TransferViewModel(
                transferService: makeService(), sheetViewModel: SheetViewModel(),
                onchainAttemptService: attempts, onchainSender: node, onchainBalanceProvider: { 50000 }
            )
            transferDefaults.set(Data("broken-test-transfer-store".utf8), forKey: "transfers")
            do {
                try await vm.payOrder(
                    order: order, speed: .normal, txFee: 123, satsPerVbyte: 2,
                    isMaxAmount: isMax, maxSendableAmount: isMax ? initialTotal - 123 : nil
                )
                XCTFail("Tracking failure was not surfaced")
            } catch {}
            XCTAssertEqual(node.calls, 1)
            transferDefaults.removeObject(forKey: "transfers")
            let restarted = TransferViewModel(
                transferService: makeService(), sheetViewModel: SheetViewModel(),
                onchainAttemptService: OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false }),
                onchainSender: node, onchainBalanceProvider: { 4000 }
            )
            try await restarted.payOrder(
                order: order, speed: .normal, txFee: 999, satsPerVbyte: 9,
                isMaxAmount: false, maxSendableAmount: nil
            )
            let tracking = try XCTUnwrap(Bitkit.TransferStorage(defaults: transferDefaults).getAll().first)
            XCTAssertEqual(tracking.txTotalSats, initialTotal)
            XCTAssertEqual(tracking.preTransferOnchainSats, 50000)
            XCTAssertEqual(tracking.fundingTxId, txid)
            XCTAssertEqual(node.calls, 1, "Transfer local resume dispatched funding twice")
        }
    }

    @MainActor
    func testAcceptedOrderFollowupKeepsAdmissionContextWhenWalletChangesAfterDispatch() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let order = IBtOrder.mock()
        node.onSend = {
            XCTAssertEqual(store.snapshot().first?.walletId, OnchainSendAttemptService.walletId(index: 0))
            node.currentWalletIndex = 1
            node.dispatchNode = NSObject()
        }
        let vm = TransferViewModel(
            transferService: makeService(), sheetViewModel: SheetViewModel(),
            onchainAttemptService: OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false }),
            onchainSender: node, onchainBalanceProvider: { node.currentWalletIndex == 0 ? 50000 : 4000 }
        )
        do {
            try await vm.payOrder(order: order, speed: .normal, txFee: 123, satsPerVbyte: 2)
        } catch {
            XCTFail("Accepted original order used the selected wallet after dispatch: \(error)")
        }
        let original = store.snapshot().first
        XCTAssertEqual(original?.walletId, OnchainSendAttemptService.walletId(index: 0))
        XCTAssertEqual(original?.txid, txid)
        XCTAssertEqual(original?.localFollowupComplete, true)
        let tracking = try Bitkit.TransferStorage(defaults: transferDefaults).getAll().first
        XCTAssertEqual(tracking?.fundingTxId, txid)
        XCTAssertEqual(tracking?.txTotalSats, order.feeSat + 123)
        XCTAssertEqual(tracking?.preTransferOnchainSats, 50000)
        XCTAssertEqual(node.calls, 1)
    }

    @MainActor
    func testConfirmedAcceptedOrderRestoresTrackingAndAckWithoutRepayment() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let order = IBtOrder.mock()
        let vm = TransferViewModel(
            transferService: makeService(), sheetViewModel: SheetViewModel(),
            onchainAttemptService: OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false }),
            onchainSender: node, onchainBalanceProvider: { 50000 }
        )
        transferDefaults.set(Data("broken-test-transfer-store".utf8), forKey: "transfers")
        do {
            try await vm.payOrder(order: order, speed: .normal, txFee: 123, satsPerVbyte: 2)
            XCTFail("Tracking failure was not surfaced")
        } catch {}
        transferDefaults.removeObject(forKey: "transfers")
        let confirmedCallback = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let receivedCallback = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmedCallback
            Bitkit.LightningService.shared.onchainTransactionReceived = receivedCallback
        }
        let wallet = makeWallet(attempts: OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false }))
        await Bitkit.LightningService.shared.onchainTransactionConfirmed?(txid)
        let tracking = try Bitkit.TransferStorage(defaults: transferDefaults).getAll().first
        XCTAssertEqual(tracking?.fundingTxId, txid)
        XCTAssertEqual(tracking?.txTotalSats, order.feeSat + 123)
        XCTAssertEqual(tracking?.preTransferOnchainSats, 50000)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
        XCTAssertEqual(node.calls, 1)
        withExtendedLifetime(wallet) {}
    }

    func testAcceptedOrdinaryRestartResumesStoredContextAndDurablyAcknowledgesActivity() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let original = OnchainSendAttemptService(store: store)
        let context = OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: ["saved-tag"], contact: nil, createdAt: 100)
        _ = try await original.send(
            using: node, address: "bcrt1qoriginal", amountSats: 4321, satsPerVbyte: 2,
            utxosToSpend: nil, isMaxAmount: true, followupContext: context
        )
        let walletId = OnchainSendAttemptService.walletId(index: 0)
        let restarted = OnchainSendAttemptService(store: store)
        let unrelatedTxid = String(repeating: "cd", count: 32)
        let unrelatedSaved = await activity.createSentOnchainActivityFromSendResult(
            txid: unrelatedTxid, address: "bcrt1qoriginal", amount: 4321, fee: 999, feeRate: 99
        )
        XCTAssertTrue(unrelatedSaved)
        store.failSave = true
        do {
            _ = try await restarted.resumeAcceptedOrdinarySend(walletId: walletId)
            XCTFail("Failed acknowledgement released the accepted guard")
        } catch {}
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, false)
        let exactSaved = try await activity.getOnchainActivityByTxId(txid: txid)
        XCTAssertEqual(exactSaved?.value, 4321)
        XCTAssertEqual(exactSaved?.address, "bcrt1qoriginal")
        XCTAssertEqual(exactSaved?.fee, 123)
        store.failSave = false
        let restartedAgain = OnchainSendAttemptService(store: store)
        do {
            _ = try await restartedAgain.send(
                using: node,
                address: "bcrt1qfresh-ui",
                amountSats: 9999,
                satsPerVbyte: 99,
                utxosToSpend: nil,
                isMaxAmount: false
            )
            XCTFail("Fresh UI dispatched before the original local follow-up was acknowledged")
        } catch {}
        let firstResolution = try await restartedAgain.resumeAcceptedOrdinarySend(walletId: walletId)
        let repeatedResolution = try await restartedAgain.resumeAcceptedOrdinarySend(walletId: walletId)
        XCTAssertEqual(firstResolution?.txid, txid)
        XCTAssertEqual(firstResolution?.amountSats, 4321)
        XCTAssertEqual(repeatedResolution?.txid, txid)
        XCTAssertEqual(node.calls, 1, "Local resume invoked node dispatch")
        let metadata = try await activity.getPreActivityMetadata(searchKey: txid)
        XCTAssertEqual(metadata?.address, "bcrt1qoriginal")
        XCTAssertEqual(metadata?.tags, ["saved-tag"])
        XCTAssertEqual(metadata?.feeRate, 2)
        let activities = try await activity.get(filter: .onchain, limit: 50, sortDirection: .desc)
        XCTAssertEqual(activities.count, 2, "Repeated follow-up duplicated a durable activity")
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
        _ = try await restartedAgain.send(using: node, address: "bcrt1qnew", amountSats: 1000, satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false)
        XCTAssertEqual(node.calls, 2)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testExactConfirmationCanFinishAcceptedIncompleteOrdinaryFollowup() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let txid = String(repeating: "ab", count: 32)
        let walletId = OnchainSendAttemptService.walletId(index: 0)
        let id = try await service.admit(
            walletId: walletId, requestId: nil, orderId: nil, address: "bcrt1qoriginal", amountSats: 1000, isMaxAmount: false,
            followupContext: OnchainSendFollowupContext(feeSats: 100, feeRate: 1, tags: [], contact: nil, createdAt: 100)
        )
        try await service.record(.accepted(txid: txid), attemptId: id)
        let unrelated = try await service.observeConfirmedTransaction(txid: String(repeating: "cd", count: 32))
        XCTAssertFalse(unrelated)
        let observed = try await service.observeConfirmedTransaction(txid: txid)
        XCTAssertTrue(observed, "Exact confirmation ignored the accepted incomplete guard")
        let resolution = try await service.resumeAcceptedOrdinarySend(walletId: walletId)
        XCTAssertEqual(resolution?.txid, txid)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
    }

    func testAcceptedOrdinaryWithoutContextOrExactDurableDetailsStaysGuarded() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let walletId = OnchainSendAttemptService.walletId(index: 0)
        let id = try await service.admit(
            walletId: walletId,
            requestId: nil,
            orderId: nil,
            address: "bcrt1qoriginal",
            amountSats: 1000,
            isMaxAmount: false
        )
        try await service.record(.accepted(txid: String(repeating: "ab", count: 32)), attemptId: id)
        do {
            _ = try await OnchainSendAttemptService(store: store).resumeAcceptedOrdinarySend(walletId: walletId)
            XCTFail("Missing local context was reconstructed from a fresh UI")
        } catch {}
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, false)
    }

    func testPaidOrderFollowupIsIdempotentAndRejectsDifferentFundingTxid() async throws {
        let service = makeService()
        let txid = String(repeating: "ab", count: 32)
        let first = try await service.createTransfer(type: .toSpending, amountSats: 1000, fundingTxId: txid, lspOrderId: "paid-order")
        let resumed = try await service.createTransfer(type: .toSpending, amountSats: 1000, fundingTxId: txid, lspOrderId: "paid-order")
        XCTAssertEqual(first, resumed)
        XCTAssertEqual(try Bitkit.TransferStorage(defaults: transferDefaults).getAll().count, 1)
        do {
            _ = try await service.createTransfer(
                type: .toSpending,
                amountSats: 1000,
                fundingTxId: String(repeating: "cd", count: 32),
                lspOrderId: "paid-order"
            )
            XCTFail("Paid order was associated with another funding transaction")
        } catch {}
        XCTAssertEqual(try Bitkit.TransferStorage(defaults: transferDefaults).getAll().first?.fundingTxId, txid)
    }

    func testPendingToSpendingActivityDoesNotStoreShortChannelId() async throws {
        var channel = IBtChannel.mock()
        channel.shortChannelId = "820100x5x0"
        let order = IBtOrder.mock(channel: channel)

        await makeService().createPendingToSpendingActivity(order: order, txId: "hwtx1", fee: 141, feeRate: 2)

        let stored = try await activity.getOnchainActivityByTxId(txid: "hwtx1")
        let onchain = try XCTUnwrap(stored)
        XCTAssertNil(onchain.channelId, "The order's short channel id must not be stored as the activity channelId")
        XCTAssertTrue(onchain.isTransfer, "A hardware funding activity must be marked as a transfer")
        XCTAssertEqual(onchain.value, order.feeSat)
    }

    /// The atomic mark-as-transfer must only touch `isTransfer`/`channelId`, preserving confirmation
    /// and fee that a concurrent watcher sync may have written.
    func testMarkOnchainActivityAsTransferPreservesConfirmationAndFee() async throws {
        let seeded = OnchainActivity(
            walletId: WalletScope.default,
            id: "hwtx2",
            txType: .sent,
            txId: "hwtx2",
            value: 1000,
            fee: 500,
            feeRate: 2,
            address: "bc1q...",
            confirmed: true,
            timestamp: 1,
            isBoosted: false,
            boostTxIds: [],
            isTransfer: false,
            doesExist: true,
            confirmTimestamp: 123,
            channelId: nil,
            transferTxId: nil,
            contact: nil,
            createdAt: 1,
            updatedAt: 1,
            seenAt: 1
        )
        try await activity.insert(.onchain(seeded))

        await activity.markOnchainActivityAsTransfer(txId: "hwtx2", channelId: "boltchan")

        let stored = try await activity.getOnchainActivityByTxId(txid: "hwtx2")
        let onchain = try XCTUnwrap(stored)
        XCTAssertTrue(onchain.isTransfer)
        XCTAssertEqual(onchain.channelId, "boltchan")
        XCTAssertTrue(onchain.confirmed, "confirmation must be preserved")
        XCTAssertEqual(onchain.fee, 500, "fee must be preserved")
    }
}
