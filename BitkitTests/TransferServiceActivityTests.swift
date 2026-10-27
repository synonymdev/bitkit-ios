@testable import Bitkit
import BitkitCore
import Combine
import LDKNode
import Paykit
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
        snapshotAppDefaults("activityDetachedContacts")
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

    private func paymentRequestRecord(
        endpoints: [String] = [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
        paymentProofs: [PaymentProofRecord] = [],
        paymentRequestId: String = "550e8400-e29b-41d4-a716-446655440000",
        state: PaymentRequestLifecycleState = .proposed,
        recurrence: PaymentRequestRecurrence? = nil
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: "pubky" + String(repeating: "y", count: 52),
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

    private func makeService() -> Bitkit.TransferService {
        Bitkit.TransferService(
            storage: Bitkit.TransferStorage(defaults: transferDefaults),
            lightningService: .shared
        )
    }

    @MainActor
    private func makeWallet(attempts: OnchainSendAttemptService) -> WalletViewModel {
        WalletViewModel(
            transferService: makeService(), sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager(), onchainAttemptService: attempts
        )
    }

    func testOrdinaryResolutionBeforePendingInitializationRestoresExactDurableResult() async throws {
        for rejected in [false, true] {
            let store = MemoryAttemptStore()
            let txid = String(repeating: rejected ? "cd" : "ab", count: 32)
            let node = AttemptNodeMock(result: rejected ? .rejected(txid: txid, reason: "fixture") : .unknown(txid: txid))
            let service = OnchainSendAttemptService(store: store)
            _ = try await service.send(using: node, address: "bcrt1qoriginal", amountSats: 4321,
                                       satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false,
                                       followupContext: OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: [], contact: nil, createdAt: 100))
            let original = try XCTUnwrap(store.snapshot().first)
            let route = await SendConfirmationView.onchainPendingRoute(txid: txid, requestId: nil, using: service)
            guard case let .onchainPending(context) = route else { return XCTFail("Original send did not retain its Pending identity") }
            XCTAssertEqual(context.attemptId, original.id)
            // Exact native observation and its Passthrough publication precede Pending initialization.
            _ = try await service.resumeAcceptedOrdinarySend(walletId: original.walletId, observedTxid: txid)
            XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
            let restarted = OnchainSendAttemptService(store: store)
            let loaded = try await SendPendingScreen.loadOrdinaryPending(using: restarted, context: context, walletId: "node:now-selected-other")
            XCTAssertEqual(loaded.attempt?.id, original.id)
            XCTAssertEqual(loaded.resolution?.txid, txid)
            XCTAssertEqual(loaded.resolution?.amountSats, 4321)
            XCTAssertEqual(node.calls, 1, "Pending recovery dispatched another payment")
        }
    }

    @MainActor
    func testStartupAcceptedResolutionBeforePendingInitializationRetainsOriginalContext() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ac", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let service = OnchainSendAttemptService(store: store)
        _ = try await service.send(using: node, address: "bcrt1qoriginal", amountSats: 4321,
                                   satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false,
                                   followupContext: OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: [], contact: nil, createdAt: 100))
        let original = try XCTUnwrap(store.snapshot().first)
        let retained = try await service.unresolvedAttempt(walletId: original.walletId)
        let route = try SendSheet.acceptedOrdinaryStartupRoute(attempt: XCTUnwrap(retained))
        // The activity event publishes and durably acknowledges before Pending subscribes/initializes.
        _ = try await service.resumeAcceptedOrdinarySend(walletId: original.walletId)
        let context: OnchainSendPendingContext? = if case let .onchainPending(value) = route {
            value
        } else {
            nil
        }
        let restarted = OnchainSendAttemptService(store: store)
        let loaded = try await SendPendingScreen.loadOrdinaryPending(
            using: restarted, context: context, walletId: "node:now-selected-other"
        )
        XCTAssertEqual(context?.attemptId, original.id)
        XCTAssertEqual(context?.walletId, original.walletId)
        XCTAssertEqual(context?.txid, txid)
        XCTAssertEqual(loaded.attempt?.id, original.id)
        XCTAssertEqual(loaded.resolution?.txid, txid)
        XCTAssertEqual(loaded.resolution?.amountSats, 4321)
        XCTAssertEqual(node.calls, 1, "Startup recovery dispatched another payment")
    }

    func testPendingInitializationRejectsOldCompletedAndReplacementContexts() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let service = OnchainSendAttemptService(store: store)
        _ = try await service.send(using: node, address: "bcrt1qoriginal", amountSats: 4321,
                                   satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false,
                                   followupContext: OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: [], contact: nil, createdAt: 100))
        let original = try XCTUnwrap(store.snapshot().first)
        let startupRoute = await SendSheet.acceptedOrdinaryStartupRoute(attempt: original)
        guard case let .onchainPending(startupContext) = startupRoute else {
            return XCTFail("Startup lost the original retained identity")
        }
        _ = try await service.resumeAcceptedOrdinarySend(walletId: original.walletId)
        let noContext = try await SendPendingScreen.loadOrdinaryPending(using: service, context: nil, walletId: original.walletId)
        XCTAssertNil(noContext.resolution, "Old completed result satisfied a new unsent Pending")
        let unsentRoute = await SendConfirmationView.onchainPendingRoute(requestId: nil, using: service)
        guard case .pending = unsentRoute else { return XCTFail("New unsent route acquired an earlier completed attempt") }
        let contexts = [
            OnchainSendPendingContext(attemptId: UUID(), walletId: original.walletId, txid: txid),
            OnchainSendPendingContext(attemptId: original.id, walletId: "node:other", txid: txid),
            OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: String(repeating: "ef", count: 32)),
        ]
        for context in contexts {
            let loaded = try await SendPendingScreen.loadOrdinaryPending(using: service, context: context, walletId: original.walletId)
            XCTAssertNil(loaded.resolution)
        }
        _ = try await service.send(using: node, address: "bcrt1qreplacement", amountSats: 9999,
                                   satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false)
        let stale = startupContext
        let replacement = try await SendPendingScreen.loadOrdinaryPending(using: service, context: stale, walletId: original.walletId)
        XCTAssertNil(replacement.resolution, "Replacement attempt used the earlier Pending identity")
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, false)
        XCTAssertEqual(node.calls, 2)
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
        .environment(PaykitPaymentRequestManager())
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
    func testVisiblePendingRecoversAcceptedFundingWithoutCompletionEvent() async throws {
        let store = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: store)
        let walletId = OnchainSendAttemptService.walletId(index: 0)
        let txid = String(repeating: "ab", count: 32)
        let id = try await attempts.admit(
            walletId: walletId, requestId: nil, orderId: "original-lost-event-order",
            address: "bcrt1qoriginal", amountSats: 1200, isMaxAmount: true,
            followupContext: OnchainSendFollowupContext(feeSats: 100, feeRate: 1, tags: [], contact: nil, createdAt: 100),
            transferContext: OnchainSendTransferContext(clientBalanceSats: 1000, txTotalSats: 1300,
                                                        preTransferOnchainSats: 1300, originalOrderFeeSats: 200)
        )
        try await attempts.record(.unknown(txid: txid), attemptId: id)
        let received = Bitkit.LightningService.shared.onchainTransactionReceived
        let confirmed = Bitkit.LightningService.shared.onchainTransactionConfirmed
        defer {
            Bitkit.LightningService.shared.onchainTransactionReceived = received
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmed
        }
        let wallet = makeWallet(attempts: attempts)
        var path: [SendRoute] = []
        let context = OnchainSendPendingContext(attemptId: id, walletId: walletId, txid: txid)
        let view = SendPendingScreen(
            paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: nil,
            routingCacheResetAttempted: false, attemptService: attempts, ordinaryPendingContext: context,
            navigationPath: Binding(get: { path }, set: { path = $0 })
        )
        .environment(PaykitPaymentRequestManager())
        .environmentObject(CurrencyViewModel())
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(ActivityListViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .environmentObject(PubkyProfileManager())
        .environmentObject(SheetViewModel())
        .environmentObject(wallet)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(PaykitPaymentActivity.shared.shouldDeferRefresh, "Idle Pending must leave discovery and recovery available")
        // Store the positive original result after initialization, without delivering a
        // native callback or a completion event to the already-visible Pending screen.
        _ = try await attempts.observeConfirmedTransaction(txid: txid)
        for _ in 0 ..< 12 {
            if store.snapshot().first?.localFollowupComplete == true {
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true,
                       "Visible Pending never reloaded the durable accepted original")
        let saved = try await activity.getOnchainActivityByTxId(txid: txid)
        XCTAssertEqual(saved?.txId, txid)
        XCTAssertEqual(saved?.isTransfer, true)
        XCTAssertTrue(try makeService().getActiveTransfers().isEmpty, "Blocktank opens no channel, so no transfer is tracked")
        let blocking = try await attempts.blockingAttempt()
        XCTAssertNil(blocking, "An accepted funding must not block later sends")
        XCTAssertTrue(path.isEmpty, "Funding recovery must not mark a new unsent payment successful")
        XCTAssertFalse(PaykitPaymentActivity.shared.shouldDeferRefresh)
    }

    @MainActor
    func testHardwareShopCandidateDoesNotCreateSentActivityUntilVerified() async throws {
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: UUID().uuidString, counterparty: "pubky" + String(repeating: "y", count: 52),
            billingPeriodStartsAt: nil
        )
        let walletId = "trezor:original-ios-wallet"
        for (index, request, verified) in [(0, Optional(requestId), false), (1, Optional(requestId), true), (2, nil, false)] {
            let txid = String(repeating: ["ab", "cd", "ef"][index], count: 32)
            let result = HwFundingBroadcastResult(txId: txid, miningFeeSats: 100, feeRate: 2, totalSpent: 1334)
            await HwSendSignView.recordPaymentResult(
                result, walletId: walletId, address: "bcrt1qoriginal", amount: 1234,
                contactPublicKey: requestId.counterparty, tags: ["original tag"], requestId: request, proofVerified: verified
            )
            let sent = try await activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
            if request != nil, !verified {
                XCTAssertNil(sent, "The local hardware txid must not become Sent activity without positive observation")
                let metadata = try await ServiceQueue.background(.core) {
                    try BitkitCore.getPreActivityMetadata(walletId: walletId, searchKey: txid, searchByAddress: false)
                }
                XCTAssertEqual(metadata?.walletId, walletId)
                XCTAssertEqual(metadata?.txId, txid)
                XCTAssertEqual(metadata?.address, "bcrt1qoriginal")
                XCTAssertEqual(metadata?.tags, ["original tag"])
                // A later positive observation resumes this exact result and existing metadata.
                await HwSendSignView.recordPaymentResult(
                    result, walletId: walletId, address: "bcrt1qoriginal", amount: 1234,
                    contactPublicKey: requestId.counterparty, tags: ["original tag"], requestId: request, proofVerified: true
                )
            }
            let completed = try await activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
            XCTAssertEqual(completed?.walletId, walletId)
            XCTAssertEqual(completed?.txId, txid)
            XCTAssertEqual(completed?.value, 1234)
            XCTAssertEqual(completed?.fee, 100)
        }
    }

    @MainActor
    func testDelayedHardwareProofRestoresOriginalSentActivityTagsAndReopenedPending() async throws {
        let identity = "pubky" + String(repeating: "z", count: 52)
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: UUID().uuidString, counterparty: "pubky" + String(repeating: "y", count: 52),
            billingPeriodStartsAt: nil
        )
        let walletId = "trezor:original-ios-wallet"
        let txid = String(repeating: "ab", count: 32)
        let result = HwFundingBroadcastResult(txId: txid, miningFeeSats: 100, feeRate: 2, totalSpent: 1334)
        await HwSendSignView.recordPaymentResult(
            result, walletId: walletId, address: "bcrt1qoriginal", amount: 1234,
            contactPublicKey: requestId.counterparty, tags: ["original tag"], requestId: requestId, proofVerified: false
        )
        let proof = PendingPaykitPaymentProof(
            identity: identity, requestId: requestId, paymentAppId: "bitkit",
            paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
            kind: .onchain, paymentStarted: true, paymentIdentifier: txid, proofData: nil,
            onchainAddress: "bcrt1qoriginal", onchainAmountSats: 1234, onchainWalletId: walletId
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [])
        let lookup = PaymentProofHardwareLookup(result: .success(TransactionDetail(
            txid: txid, received: 0, sent: 1334, net: -1334, amount: 1234, fee: 100, direction: .sent,
            blockHeight: nil, timestamp: nil, confirmations: 0, inputs: [], outputs: [], size: 112, vsize: 112, weight: 448, feeRate: 2
        )))
        let service = PaykitPaymentProofService(
            sdk: sdk, store: store, hardwareTransactionLookup: lookup,
            attemptService: OnchainSendAttemptService(store: MemoryAttemptStore()), logInfo: { _ in }, logWarning: { _ in }
        )
        await service.reconcile()
        let sent = try await activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
        XCTAssertEqual(sent?.txId, txid)
        XCTAssertEqual(sent?.walletId, walletId)
        XCTAssertEqual(sent?.value, 1234)
        XCTAssertEqual(sent?.fee, 100)
        XCTAssertEqual(sent?.contact, PubkyPublicKeyFormat.normalized(requestId.counterparty))
        let tags = try await activity.tags(forActivity: txid, walletId: walletId)
        XCTAssertEqual(tags, ["original tag"])
        await service.consumeOnchainPaymentResolution(
            .init(identity: identity, requestId: requestId, transactionId: txid, walletId: walletId),
            activeIdentity: identity
        )
        let confirmedCallback = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let receivedCallback = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmedCallback
            Bitkit.LightningService.shared.onchainTransactionReceived = receivedCallback
        }
        let wallet = makeWallet(attempts: OnchainSendAttemptService(store: MemoryAttemptStore()))
        wallet.sendAmountSats = 9999
        let profile = PubkyProfileManager()
        profile.publicKey = identity
        var path: [SendRoute] = []
        let view = SendPendingScreen(
            paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: requestId,
            routingCacheResetAttempted: false, hardwareWalletId: walletId, hardwareTransactionId: txid,
            hardwarePaymentIdentity: identity, proofService: service,
            navigationPath: Binding(get: { path }, set: { path = $0 })
        )
        .environment(PaykitPaymentRequestManager())
        .environmentObject(CurrencyViewModel()).environmentObject(SettingsViewModel.shared)
        .environmentObject(ActivityListViewModel()).environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel()).environmentObject(profile)
        .environmentObject(SheetViewModel()).environmentObject(wallet)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0 ..< 30 where path.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(path, [.recoveredSuccess(paymentId: txid, walletId: walletId)], "Consumed publisher must not strand durable verified Pending")
        XCTAssertEqual(wallet.sendAmountSats, 9999)
    }

    @MainActor
    func testRecoveredSuccessUsesOriginalWalletActivityWithoutReadingTheNewDraft() async throws {
        let txid = String(repeating: "ab", count: 32)
        let originalWallet = "trezor:original-ios-wallet"
        let otherWallet = WalletScope.default
        for (walletId, amount) in [(originalWallet, UInt64(10000)), (otherWallet, UInt64(30000))] {
            try await activity.insert(.onchain(OnchainActivity(
                walletId: walletId, id: txid, txType: .sent, txId: txid, value: amount, fee: 143, feeRate: 1,
                address: "bcrt1qoriginal", confirmed: false, timestamp: 1, isBoosted: false, boostTxIds: [],
                isTransfer: false, doesExist: true, confirmTimestamp: nil, channelId: nil, transferTxId: nil,
                contact: nil, createdAt: 1, updatedAt: 1, seenAt: 1
            )))
        }
        for index in 0 ..< 51 {
            try await activity.insert(.onchain(OnchainActivity(
                walletId: originalWallet, id: "newer-\(index)", txType: .sent, txId: "newer-\(index)", value: 500,
                fee: 143, feeRate: 1, address: "bcrt1qnewer", confirmed: false, timestamp: UInt64(index + 100),
                isBoosted: false, boostTxIds: [], isTransfer: false, doesExist: true, confirmTimestamp: nil,
                channelId: nil, transferTxId: nil, contact: nil, createdAt: UInt64(index + 100),
                updatedAt: UInt64(index + 100), seenAt: UInt64(index + 100)
            )))
        }
        let newest = try await activity.get(filter: .all, limit: 50, walletId: originalWallet)
        XCTAssertFalse(newest.contains { item in
            guard case let .onchain(onchain) = item else { return false }
            return onchain.txId == txid
        }, "Fixture must exercise recovery outside the newest activity page")
        do {
            _ = try await SendSuccess.findRecoveredActivity(paymentId: txid, walletId: "trezor:absent")
            XCTFail("Recovery crossed wallet scope")
        } catch {}
        do {
            _ = try await SendSuccess.findRecoveredActivity(paymentId: "absent", walletId: originalWallet)
            XCTFail("Recovery used another transaction")
        } catch {}
        let confirmed = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let received = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmed
            Bitkit.LightningService.shared.onchainTransactionReceived = received
        }
        let wallet = makeWallet(attempts: OnchainSendAttemptService(store: MemoryAttemptStore()))
        wallet.sendAmountSats = 20000
        var draftReads = 0
        func draftAmount() -> Int? {
            draftReads += 1
            return wallet.sendAmountSats.map(Int.init)
        }
        XCTAssertNil(SendSuccess.displayAmountSats(isRecoveredPayment: true, activity: nil, draftAmount: draftAmount()))
        for (walletId, expected) in [(originalWallet, 10000), (otherWallet, 30000)] {
            let original = try await SendSuccess.findRecoveredActivity(paymentId: txid, walletId: walletId)
            XCTAssertEqual(SendSuccess.displayAmountSats(isRecoveredPayment: true, activity: original, draftAmount: draftAmount()), expected)
        }
        XCTAssertEqual(draftReads, 0, "Recovery must not read another request's draft, even before activity is available")
        XCTAssertEqual(wallet.sendAmountSats, 20000)
        XCTAssertEqual(SendSuccess.displayAmountSats(isRecoveredPayment: false, activity: nil, draftAmount: draftAmount()), 20000)
        XCTAssertEqual(draftReads, 1, "Ordinary and Quickpay success retain their existing display amount")
    }

    @MainActor
    func testHardwarePendingNavigatesBeforeAcknowledgementAndRejectsOtherContexts() async throws {
        let identity = "pubky" + String(repeating: "z", count: 52)
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: UUID().uuidString, counterparty: "pubky" + String(repeating: "y", count: 52), billingPeriodStartsAt: nil
        )
        let walletId = "trezor:original-ios-wallet"
        let txid = String(repeating: "ab", count: 32)
        let request = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(
            endpoints: [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue], paymentRequestId: requestId.paymentRequestId
        ), now: Date()))
        var proof = PendingPaykitPaymentProof(
            identity: identity, requestId: requestId, paymentAppId: "bitkit",
            paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
            kind: .onchain, paymentStarted: true, paymentIdentifier: txid, proofData: txid,
            onchainAddress: "bcrt1qoriginal", onchainAmountSats: 1234, onchainWalletId: walletId,
            onchainAcceptanceVerified: true, onchainLocalFollowupComplete: true
        )
        proof.onchainResolutionAwaitingConsumption = true
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [])
        let service = PaykitPaymentProofService(
            sdk: sdk, store: store, hardwareTransactionLookup: PaymentProofHardwareLookup(result: .failure(CancellationError())),
            attemptService: OnchainSendAttemptService(store: MemoryAttemptStore()), logInfo: { _ in }, logWarning: { _ in }
        )
        await service.reconcile()
        await sdk.suspendIdentityStatus()
        await sdk.setIdentityAvailable(false)
        let confirmedCallback = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let receivedCallback = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmedCallback
            Bitkit.LightningService.shared.onchainTransactionReceived = receivedCallback
        }
        let wallet = makeWallet(attempts: OnchainSendAttemptService(store: MemoryAttemptStore()))
        let otherIdentity = "pubky" + String(repeating: "x", count: 52)
        let contexts = [(otherIdentity, walletId, txid), (identity, "trezor:other", txid),
                        (identity, walletId, String(repeating: "cd", count: 32)), (identity, walletId, txid)]
        for (index, context) in contexts.enumerated() {
            let isOriginalContext = index == contexts.count - 1
            if isOriginalContext {
                await service.consumeOnchainPaymentResolution(
                    .init(identity: identity, requestId: requestId, transactionId: txid, walletId: walletId), activeIdentity: nil
                )
            }
            let profile = PubkyProfileManager()
            profile.publicKey = context.0
            var path: [SendRoute] = []
            var navigatedOnMainThread = true
            let navigation = expectation(description: "Hardware resolution navigates only its original context")
            navigation.isInverted = !isOriginalContext
            let view = SendPendingScreen(
                paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: requestId,
                routingCacheResetAttempted: false, hardwareWalletId: context.1, hardwareTransactionId: context.2,
                hardwarePaymentIdentity: identity, proofService: service, navigationPath: Binding(get: { path }, set: {
                    navigatedOnMainThread = Thread.isMainThread
                    path = $0
                    navigation.fulfill()
                })
            )
            .environment(PaykitPaymentRequestManager())
            .environmentObject(CurrencyViewModel()).environmentObject(SettingsViewModel.shared)
            .environmentObject(ActivityListViewModel()).environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel()).environmentObject(profile)
            .environmentObject(SheetViewModel()).environmentObject(wallet)
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            if isOriginalContext {
                let completed = await service.completeHardwareOnchainPayment(request, paymentIdentity: identity, walletId: walletId, txid: txid)
                XCTAssertTrue(completed)
            }
            await fulfillment(of: [navigation], timeout: 2)
            XCTAssertEqual(path, isOriginalContext ? [.recoveredSuccess(paymentId: txid, walletId: walletId)] : [])
            XCTAssertTrue(navigatedOnMainThread)
            window.isHidden = true
            window.rootViewController = nil
        }
        let beforeAcknowledgement = await store.snapshot()
        XCTAssertEqual(beforeAcknowledgement, [proof])
        func hasPendingAcknowledgement() -> Bool {
            var pending = false
            let observation = PaykitPaymentProofService.onchainPaymentResolutionPublisher.sink {
                if $0.requestId == requestId, $0.identity == identity, $0.walletId == walletId, $0.transactionId == txid {
                    pending = true
                }
            }
            observation.cancel()
            return pending
        }
        XCTAssertTrue(hasPendingAcknowledgement())
        await sdk.resumeIdentityStatus()
        let acknowledgementFinished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !hasPendingAcknowledgement()
        }, object: nil)
        await fulfillment(of: [acknowledgementFinished], timeout: 2)
        let afterFailedAcknowledgement = await store.snapshot()
        XCTAssertEqual(afterFailedAcknowledgement, [proof], "Unavailable SDK identity must retain the durable proof and acknowledgement")
    }

    @MainActor
    func testHardwareProofSubmissionRetryPreservesContactEdits() async throws {
        let identity = "pubky" + String(repeating: "z", count: 52)
        let original = "pubky" + String(repeating: "y", count: 52)
        let reassigned = "pubky" + String(repeating: "x", count: 52)
        for (index, editedContact) in [String?.none, Optional(reassigned)].enumerated() {
            let requestId = PaykitPaymentRequest.ID(paymentRequestId: UUID().uuidString, counterparty: original,
                                                    billingPeriodStartsAt: nil)
            let walletId = "trezor:original-ios-wallet"
            let txid = String(repeating: index == 0 ? "ab" : "cd", count: 32)
            let store = PaymentProofMemoryStore()
            await store.seed([PendingPaykitPaymentProof(identity: identity, requestId: requestId,
                                                        paymentAppId: "bitkit",
                                                        paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
                                                        kind: .onchain,
                                                        paymentStarted: true, paymentIdentifier: txid, proofData: nil,
                                                        onchainAddress: "bcrt1qoriginal",
                                                        onchainAmountSats: 1234, onchainWalletId: walletId)])
            let sdk = try PaymentProofSdkMock(identity: identity, records: [paymentRequestRecord(
                endpoints: [PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue], paymentRequestId: requestId.paymentRequestId
            )])
            await sdk.setSubmissionFailure(true)
            let lookup = PaymentProofHardwareLookup(result: .success(TransactionDetail(
                txid: txid, received: 0, sent: 1334, net: -1334, amount: 1234, fee: 100, direction: .sent,
                blockHeight: nil, timestamp: nil, confirmations: 0, inputs: [], outputs: [], size: 112, vsize: 112, weight: 448, feeRate: 2
            )))
            func service() -> PaykitPaymentProofService {
                PaykitPaymentProofService(sdk: sdk, store: store, hardwareTransactionLookup: lookup,
                                          attemptService: OnchainSendAttemptService(store: MemoryAttemptStore()), logInfo: { _ in },
                                          logWarning: { _ in })
            }
            await service().reconcile()
            let sent = try await activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
            XCTAssertEqual(sent?.contact, PubkyPublicKeyFormat.normalized(original))
            let completedProofs = await store.snapshot()
            XCTAssertEqual(completedProofs.first?.onchainLocalFollowupComplete, true)
            let failedSubmissions = await sdk.submissionCount()
            XCTAssertEqual(failedSubmissions, 1, "Fixture must exercise actual failed SDK submission after local follow-up")
            try await activity.setContact(editedContact, forActivity: txid, walletId: walletId)
            await service().reconcile() // restart after SDK failure; original durable proof retained
            let saved = try await activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
            XCTAssertEqual(
                saved?.contact,
                editedContact.flatMap(PubkyPublicKeyFormat.normalized),
                "Proof delivery retry overwrote a later Details contact edit"
            )
            let retrySubmissions = await sdk.submissionCount()
            XCTAssertEqual(retrySubmissions, 2)
            let lookups = await lookup.calls()
            XCTAssertEqual(lookups.count, 1, "Verified proof delivery retry must not repeat transaction observation or payment")
        }
    }

    @MainActor
    func testReceivedEventPreservesCompletedOrdinaryContactEdits() async throws {
        let confirmedCallback = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let receivedCallback = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmedCallback
            Bitkit.LightningService.shared.onchainTransactionReceived = receivedCallback
        }
        let original = "pubky" + String(repeating: "y", count: 52)
        let reassigned = "pubky" + String(repeating: "x", count: 52)
        for (index, editedContact) in [String?.none, Optional(reassigned)].enumerated() {
            let store = MemoryAttemptStore()
            let txid = String(repeating: index == 0 ? "ab" : "cd", count: 32)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            let attempts = OnchainSendAttemptService(store: store)
            _ = try await attempts.send(using: node, address: "bcrt1qoriginal", amountSats: 4321, satsPerVbyte: 2,
                                        utxosToSpend: nil, isMaxAmount: false,
                                        followupContext: OnchainSendFollowupContext(
                                            feeSats: 123,
                                            feeRate: 2,
                                            tags: [],
                                            contact: original,
                                            createdAt: 100
                                        ))
            _ = try await attempts.resumeAcceptedOrdinarySend(walletId: OnchainSendAttemptService.walletId(index: node.currentWalletIndex))
            XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
            try await activity.setContact(editedContact, forActivity: txid)
            let wallet = makeWallet(attempts: OnchainSendAttemptService(store: store))
            await Bitkit.LightningService.shared.onchainTransactionReceived?(txid.uppercased())
            let saved = try await activity.getOnchainActivityByTxId(txid: txid)
            XCTAssertEqual(
                saved?.contact,
                editedContact.flatMap(PubkyPublicKeyFormat.normalized),
                "Delayed native event overwrote a later Details contact edit"
            )
            XCTAssertEqual(node.calls, 1, "Completed follow-up must not dispatch another payment")
            withExtendedLifetime(wallet) {}
        }
    }

    @MainActor
    func testHardwarePendingSkipsSavingsGuardAndResolvesOnlyOriginalWalletAndTxid() async throws {
        let identity = "pubky" + String(repeating: "z", count: 52)
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: UUID().uuidString, counterparty: "pubky" + String(repeating: "y", count: 52),
            billingPeriodStartsAt: nil
        )
        let walletId = "trezor:original-ios-wallet"
        let txid = String(repeating: "ab", count: 32)
        let proof = PendingPaykitPaymentProof(
            identity: identity, requestId: requestId, paymentAppId: "bitkit",
            paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
            kind: .onchain, paymentStarted: true, paymentIdentifier: txid, proofData: nil,
            onchainAddress: "bcrt1qoriginal", onchainAmountSats: 1234, onchainWalletId: walletId
        )
        let store = PaymentProofMemoryStore()
        await store.seed([proof])
        let sdk = PaymentProofSdkMock(identity: identity, records: [])
        func lookup(_ txid: String) -> PaymentProofHardwareLookup {
            PaymentProofHardwareLookup(result: .success(TransactionDetail(
                txid: txid, received: 0, sent: 1334, net: -1334, amount: 1234, fee: 100, direction: .sent,
                blockHeight: nil, timestamp: nil, confirmations: 0, inputs: [], outputs: [], size: 112, vsize: 112, weight: 448, feeRate: 1
            )))
        }
        let service = PaykitPaymentProofService(
            sdk: sdk, store: store, hardwareTransactionLookup: lookup(txid),
            attemptService: OnchainSendAttemptService(store: MemoryAttemptStore()), logInfo: { _ in }, logWarning: { _ in }
        )
        let savingsStore = HardwarePendingSavingsSpy()
        let attempts = OnchainSendAttemptService(store: savingsStore)
        let confirmedCallback = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let receivedCallback = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmedCallback
            Bitkit.LightningService.shared.onchainTransactionReceived = receivedCallback
        }
        // The spy belongs to Pending, so wallet startup's independent transfer recovery
        // cannot be mistaken for a lookup made by the screen.
        let wallet = makeWallet(attempts: OnchainSendAttemptService(store: MemoryAttemptStore()))
        wallet.sendAmountSats = 9999
        let profile = PubkyProfileManager()
        profile.publicKey = identity
        var path: [SendRoute] = []
        let view = SendPendingScreen(
            paymentHash: nil, retryRoute: .confirm, paymentRequest: nil, paykitPaymentRequestId: requestId,
            routingCacheResetAttempted: false, attemptService: attempts,
            hardwareWalletId: walletId, hardwareTransactionId: txid, hardwarePaymentIdentity: identity, proofService: service,
            navigationPath: Binding(get: { path }, set: { path = $0 })
        )
        .environment(PaykitPaymentRequestManager())
        .environmentObject(CurrencyViewModel())
        .environmentObject(SettingsViewModel.shared)
        .environmentObject(ActivityListViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .environmentObject(profile)
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
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(savingsStore.loadCount, 0, "Hardware Pending must not inspect an unrelated selected node guard")
        XCTAssertTrue(path.isEmpty, "The candidate txid alone must not open Bitcoin Sent")
        let original = try await service.pendingOnchainPayment(requestId: requestId, identity: identity)
        XCTAssertEqual(original?.onchainAmountSats, 1234)
        XCTAssertEqual(original?.onchainWalletId, walletId)

        let wrongTxid = String(repeating: "cd", count: 32)
        var wrongProof = proof
        wrongProof.paymentIdentifier = wrongTxid
        await store.seed([wrongProof])
        let wrongService = PaykitPaymentProofService(
            sdk: sdk, store: store, hardwareTransactionLookup: lookup(wrongTxid),
            attemptService: OnchainSendAttemptService(store: MemoryAttemptStore()), logInfo: { _ in }, logWarning: { _ in }
        )
        await wrongService.reconcile()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(path.isEmpty, "Another txid for the same request must not resolve the original hardware wait")

        let otherIdentity = "pubky" + String(repeating: "x", count: 52)
        let otherProof = PendingPaykitPaymentProof(
            identity: otherIdentity, requestId: requestId, paymentAppId: "bitkit", paymentEndpointIdentifier: proof.paymentEndpointIdentifier,
            kind: .onchain, paymentStarted: true, paymentIdentifier: txid, proofData: nil,
            onchainAddress: proof.onchainAddress, onchainAmountSats: 7777, onchainWalletId: walletId
        )
        profile.publicKey = otherIdentity
        await sdk.setIdentity(otherIdentity)
        await store.seed([otherProof])
        await service.reconcile()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(path.isEmpty, "A profile switch must not resolve another identity's same request/wallet/txid")

        profile.publicKey = identity
        await sdk.setIdentity(identity)
        await store.seed([proof])
        await service.reconcile()
        for _ in 0 ..< 20 where path.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(path, [.recoveredSuccess(paymentId: txid, walletId: walletId)])
        XCTAssertEqual(wallet.sendAmountSats, 9999)
        XCTAssertEqual(savingsStore.loadCount, 0)
    }

    @MainActor
    func testReceivedExactRequestAndOrderObservationPromotesBeforeConfirmation() async throws {
        let confirmed = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let received = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmed
            Bitkit.LightningService.shared.onchainTransactionReceived = received
        }
        for isOrder in [false, true] {
            for refused in [false, true] {
                transferDefaults.removeObject(forKey: "transfers")
                let store = MemoryAttemptStore()
                let txid = String(repeating: isOrder ? "cd" : "ab", count: 32)
                let sender = AttemptNodeMock(result: refused ? .rejected(txid: txid, reason: "fixture refusal") : .unknown(txid: txid))
                let request = PaykitPaymentRequest.ID(paymentRequestId: UUID().uuidString,
                                                      counterparty: "pubky" + String(repeating: "y", count: 52),
                                                      billingPeriodStartsAt: nil)
                let service = OnchainSendAttemptService(store: store)
                _ = try await service.send(using: sender, address: "original", amountSats: 4321,
                                           satsPerVbyte: 2, utxosToSpend: nil, isMaxAmount: false,
                                           requestId: isOrder ? nil : request, orderId: isOrder ? "original-order" : nil,
                                           followupContext: .init(feeSats: 123, feeRate: 2, tags: [], contact: nil, createdAt: 100),
                                           transferContext: isOrder ? .init(
                                               clientBalanceSats: 3333,
                                               txTotalSats: 4444,
                                               preTransferOnchainSats: 10000
                                           ) : nil)
                let wallet = makeWallet(attempts: service)
                await Bitkit.LightningService.shared.onchainTransactionReceived?(String(repeating: "ef", count: 32))
                XCTAssertNotEqual(store.snapshot().first?.status, .accepted)
                await Bitkit.LightningService.shared.onchainTransactionReceived?(txid)
                XCTAssertEqual(
                    store.snapshot().first?.status,
                    .accepted,
                    "Exact outgoing observation did not promote request/order before confirmation"
                )
                XCTAssertEqual(store.snapshot().first?.txid, txid)
                XCTAssertEqual(store.snapshot().first?.walletId, OnchainSendAttemptService.walletId(index: sender.currentWalletIndex))
                if isOrder {
                    XCTAssertTrue(try Bitkit.TransferStorage(defaults: transferDefaults).getAll().isEmpty)
                    XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
                }
                XCTAssertEqual(sender.calls, 1)
                withExtendedLifetime(wallet) {}
            }
        }
    }

    @MainActor
    func testSuccessorWinnerWritesExactFeeAndRateIntoDetailsAndDurableMetadata() async throws {
        let store = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: store, winningFee: { _ in 281 })
        let sender = PreparedAttemptNodeMock()
        sender.miningFee = 143
        _ = try await attempts.send(using: sender, address: "bcrt1qoriginal", amountSats: sender.amount,
                                    satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false,
                                    followupContext: .init(feeSats: 143, feeRate: 1, tags: ["original"], contact: nil, createdAt: 100))
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "da", count: 32)
        sender.miningFee = 281
        sender.result = .accepted(txid: sender.txid)
        _ = try await attempts.retrySamePayment(using: sender,
                                                context: .init(attemptId: original.id, walletId: original.walletId, txid: original.txid),
                                                satsPerVbyte: 2, authorize: { _, _ in })
        _ = await activity.createSentOnchainActivityFromSendResult(
            txid: sender.txid, address: "bcrt1qoriginal", amount: sender.amount, fee: 143, feeRate: 1
        )
        let resolved = try await attempts.resumeAcceptedOrdinarySend(walletId: original.walletId)
        XCTAssertEqual(resolved?.activity.fee, 281)
        XCTAssertEqual(resolved?.activity.feeRate, 2)
        XCTAssertEqual(resolved?.activity.txId, sender.txid)
        XCTAssertEqual(resolved?.activity.value, sender.amount)
        let savedTags = try await activity.tags(forActivity: sender.txid)
        XCTAssertEqual(savedTags, ["original"])
        XCTAssertEqual(store.snapshot().first?.followupContext?.feeSats, 281)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
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
    func testRestoredGoldenShopAttemptCompletesObservedOriginalCandidateWithoutNewPayment() async throws {
        let envelope = try JSONDecoder().decode(WalletBackupV1.self, from: PaykitPaymentStateBackupTests.completeAttemptGolden())
        let state = try XCTUnwrap(envelope.paykitPaymentState)
        let store = MemoryAttemptStore()
        let attempts = OnchainSendAttemptService(store: store)
        let proofs = PaymentProofMemoryStore()
        let payer = "pubky" + String(repeating: "z", count: 52)
        let sdk = PaymentProofSdkMock(identity: payer, records: [])
        await sdk.setSubmissionFailure(true)
        let service = PaykitPaymentProofService(sdk: sdk, store: proofs, attemptService: attempts, logInfo: { _ in }, logWarning: { _ in })
        try await service.restoreBackup(state, wallet: PaykitPaymentStateBackupTests.goldenWallet(index: 0))
        let restored = try XCTUnwrap(store.snapshot().first)
        let requestId = try XCTUnwrap(restored.requestId)
        let winner = String(repeating: "ab", count: 32)
        XCTAssertEqual(restored.txid, String(repeating: "cd", count: 32))
        XCTAssertEqual(restored.status, .unknown)
        XCTAssertFalse(restored.localFollowupComplete)
        // Multiple restored candidates require exact original-wallet confirmation, not a queued received event.
        let observed = try await attempts.observeTransaction(txid: winner, walletId: restored.walletId, isConfirmed: true)
        XCTAssertTrue(observed)
        let context = OnchainSendPendingContext(attemptId: restored.id, walletId: restored.walletId, txid: restored.txid)
        await sdk.setIdentity("pubky" + String(repeating: "y", count: 52))
        let foreignResolution = await service.resolvedOnchainPayment(requestId: requestId, identity: payer, context: context)
        XCTAssertNil(foreignResolution, "Selected profile must not complete another original payer's proof")
        await sdk.setIdentity(payer)
        let resolution = await service.resolvedOnchainPayment(requestId: requestId, identity: payer, context: context)
        XCTAssertEqual(resolution?.transactionId, winner)
        let completed = try await proofs.load().first
        XCTAssertEqual(completed?.paymentIdentifier, winner)
        XCTAssertEqual(completed?.proofData, winner)
        XCTAssertEqual(completed?.onchainAcceptanceVerified, true)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
        let saved = try await activity.getOnchainActivityByTxId(txid: winner)
        XCTAssertEqual(saved?.value, 1234)
        XCTAssertEqual(saved?.contact, requestId.counterparty)
        XCTAssertEqual(store.snapshot().first?.recoveryContext?.candidateTxids.count, 2)
        // There is no OnchainSending/native broadcast dependency in restore or local completion.
    }

    func testAcceptedOrdinaryRecoveryAssociatesSyncCreatedSentRowWithoutDetachedContact() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "19", count: 32)
        let contact = "pubky" + String(repeating: "y", count: 52)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let original = OnchainSendAttemptService(store: store)
        _ = try await original.send(
            using: node, address: "bcrt1qoriginal", amountSats: 4321, satsPerVbyte: 2,
            utxosToSpend: nil, isMaxAmount: false,
            followupContext: OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: [], contact: contact, createdAt: 100)
        )
        var expectedAttempt = try XCTUnwrap(store.snapshot().first)
        let walletId = expectedAttempt.walletId
        let inserted = await activity.createSentOnchainActivityFromSendResult(
            txid: txid, address: "bcrt1qoriginal", amount: 4321, fee: 123, feeRate: 2
        )
        XCTAssertTrue(inserted)
        let syncedRow = try await activity.getOnchainActivityByTxId(txid: txid)
        let synced = try XCTUnwrap(syncedRow)
        let activityWalletId = synced.walletId
        XCTAssertEqual(activityWalletId, Bitkit.WalletScope.default)
        XCTAssertNil(synced.contact)
        XCTAssertFalse(activity.isContactDetached(activityId: synced.id, walletId: activityWalletId))
        // An unrelated wallet's removal must not suppress the original wallet's attribution.
        activity.setContactDetached(true, activityId: synced.id, walletId: "trezor:other-wallet")
        activity.setContactDetached(true, activityId: "other-activity", walletId: activityWalletId)
        let restarted = OnchainSendAttemptService(store: store)
        let resolution = try await restarted.resumeAcceptedOrdinarySend(walletId: walletId)
        let repeated = try await restarted.resumeAcceptedOrdinarySend(walletId: walletId)
        let saved = try await activity.getOnchainActivityByTxId(txid: txid)
        XCTAssertEqual(saved?.contact, PubkyPublicKeyFormat.normalized(contact))
        XCTAssertEqual(resolution?.contact, PubkyPublicKeyFormat.normalized(contact))
        XCTAssertEqual(repeated?.contact, PubkyPublicKeyFormat.normalized(contact))
        XCTAssertEqual(saved?.id, synced.id)
        XCTAssertFalse(activity.isContactDetached(activityId: synced.id, walletId: activityWalletId))
        XCTAssertTrue(activity.isContactDetached(activityId: synced.id, walletId: "trezor:other-wallet"))
        expectedAttempt.localFollowupComplete = true
        XCTAssertEqual(store.snapshot().first, expectedAttempt)
        XCTAssertEqual(node.calls, 1, "Restoring contact attribution dispatched another payment")
    }

    func testAcceptedOrdinaryRestartResumesStoredContextAndDurablyAcknowledgesActivity() async throws {
        let originalContact = "pubky" + String(repeating: "y", count: 52)
        let reassigned = "pubky" + String(repeating: "x", count: 52)
        for (index, editedContact) in [String?.none, Optional(reassigned)].enumerated() {
            let store = MemoryAttemptStore()
            let txid = String(repeating: index == 0 ? "ab" : "ef", count: 32)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            let original = OnchainSendAttemptService(store: store)
            let context = OnchainSendFollowupContext(feeSats: 123, feeRate: 2, tags: ["saved-tag"], contact: originalContact, createdAt: 100)
            _ = try await original.send(
                using: node, address: "bcrt1qoriginal", amountSats: 4321, satsPerVbyte: 2,
                utxosToSpend: nil, isMaxAmount: true, followupContext: context
            )
            var expectedAttempt = try XCTUnwrap(store.snapshot().first)
            let walletId = OnchainSendAttemptService.walletId(index: 0)
            let restarted = OnchainSendAttemptService(store: store)
            let unrelatedTxid = String(repeating: index == 0 ? "cd" : "ac", count: 32)
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
            XCTAssertEqual(exactSaved?.contact, PubkyPublicKeyFormat.normalized(originalContact))
            try await activity.setContact(editedContact, forActivity: txid)
            XCTAssertEqual(try activity.isContactDetached(activityId: XCTUnwrap(exactSaved).id,
                                                          walletId: XCTUnwrap(exactSaved).walletId), editedContact == nil)
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
            XCTAssertEqual(firstResolution?.contact, editedContact.flatMap(PubkyPublicKeyFormat.normalized))
            XCTAssertEqual(repeatedResolution?.contact, editedContact.flatMap(PubkyPublicKeyFormat.normalized))
            XCTAssertEqual(repeatedResolution?.txid, txid)
            XCTAssertEqual(node.calls, 1, "Local resume invoked node dispatch")
            let durableActivity = try await activity.getOnchainActivityByTxId(txid: txid)
            let durableTags = try await activity.tags(forActivity: txid)
            XCTAssertEqual(durableActivity?.address, "bcrt1qoriginal")
            XCTAssertEqual(durableActivity?.contact, editedContact.flatMap(PubkyPublicKeyFormat.normalized))
            XCTAssertEqual(durableTags, ["saved-tag"])
            XCTAssertEqual(durableActivity?.feeRate, 2)
            let activities = try await activity.get(filter: .onchain, limit: 50, sortDirection: .desc)
            XCTAssertEqual(activities.count, (index + 1) * 2, "Repeated follow-up duplicated a durable activity")
            expectedAttempt.localFollowupComplete = true
            XCTAssertEqual(store.snapshot().first, expectedAttempt, "Recovery changed the original accepted payment context")
            _ = try await restartedAgain.send(
                using: node,
                address: "bcrt1qnew",
                amountSats: 1000,
                satsPerVbyte: 1,
                utxosToSpend: nil,
                isMaxAmount: false
            )
            XCTAssertEqual(node.calls, 2)
            XCTAssertEqual(store.snapshot().count, 1)
        }
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
        let context = OnchainSendPendingContext(attemptId: id, walletId: walletId, txid: String(repeating: "ab", count: 32))
        let loaded = try await SendPendingScreen.loadOrdinaryPending(
            using: OnchainSendAttemptService(store: store), context: context, walletId: walletId
        )
        XCTAssertEqual(loaded.attempt?.id, id)
        XCTAssertEqual(loaded.attempt?.amountSats, 1000)
        XCTAssertEqual(loaded.attempt?.txid, context.txid)
        XCTAssertEqual(loaded.attempt?.status, .accepted)
        XCTAssertTrue(loaded.followupUnavailable)
        XCTAssertNil(loaded.resolution)
    }

    @MainActor
    func testHardwareResolutionDoesNotReplayContactIntoSavingsOrOverwriteHardwareEdit() async throws {
        let identity = "pubky" + String(repeating: "z", count: 52)
        let contact = "pubky" + String(repeating: "y", count: 52)
        let edited = "pubky" + String(repeating: "x", count: 52)
        let request = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(), now: Date()))
        for (index, hardwareEdit) in [nil, edited].enumerated() {
            let txid = String(repeating: index == 0 ? "ab" : "cd", count: 32)
            let walletId = "trezor:original-resolution-wallet"
            let created = await activity.createSentOnchainActivityFromSendResult(
                txid: txid, address: "bcrt1qoriginal", amount: 1000, fee: 100, feeRate: 1,
                contact: hardwareEdit, walletId: walletId
            )
            XCTAssertTrue(created)
            let createdSavings = await activity.createSentOnchainActivityFromSendResult(
                txid: txid, address: "bcrt1qsavings", amount: 1000, fee: 100, feeRate: 1,
                contact: edited, walletId: WalletScope.default
            )
            XCTAssertTrue(createdSavings)
            await AppScene.associateResolvedPaykitOnchainPayment(
                PaykitOnchainPaymentResolution(identity: identity, requestId: request.id, transactionId: txid, walletId: walletId),
                activeIdentity: identity, activity: Bitkit.ActivityListViewModel(transferService: makeService())
            )
            let hardware = try await activity.getOnchainActivityByTxId(txid: txid, walletId: walletId)
            let savings = try await activity.getOnchainActivityByTxId(txid: txid)
            XCTAssertEqual(hardware?.contact, hardwareEdit.flatMap(PubkyPublicKeyFormat.normalized))
            XCTAssertEqual(savings?.contact, PubkyPublicKeyFormat.normalized(edited), "Hardware resolution rewrote unrelated Savings contact")
            XCTAssertNotEqual(savings?.contact, PubkyPublicKeyFormat.normalized(contact))
        }
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

private final class HardwarePendingSavingsSpy: OnchainSendAttemptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var loadCount: Int {
        lock.withLock { count }
    }

    func load() -> [OnchainSendAttempt] {
        lock.withLock { count += 1 }; return []
    }

    func save(_: [OnchainSendAttempt]) {}
}
