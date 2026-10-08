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
            lightningService: .shared,
            blocktankService: Bitkit.CoreService.shared.blocktank,
            isGeoBlocked: { false }
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
        let records = try makeService().getActiveTransfers()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.lspOrderId, "original-lost-event-order")
        XCTAssertTrue(path.isEmpty, "Funding recovery must not mark a new unsent payment successful")
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
            identity: identity, requestId: requestId, paymentAppId: "bitkit", paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
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
        await service.consumeOnchainPaymentResolution(.init(identity: identity, requestId: requestId, transactionId: txid, walletId: walletId))
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
        XCTAssertEqual(path, [.success(paymentId: txid, walletId: walletId)], "Consumed publisher must not strand durable verified Pending")
        XCTAssertEqual(wallet.sendAmountSats, 9999)
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
            identity: identity, requestId: requestId, paymentAppId: "bitkit", paymentEndpointIdentifier: PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue,
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
        XCTAssertEqual(path, [.success(paymentId: txid, walletId: walletId)])
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
                let service = OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false })
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
                    let tracking = try Bitkit.TransferStorage(defaults: transferDefaults).getAll().first
                    XCTAssertEqual(tracking?.fundingTxId, txid)
                    XCTAssertEqual(tracking?.txTotalSats, 4444)
                    XCTAssertEqual(tracking?.preTransferOnchainSats, 10000)
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
        _ = try await attempts.send(using: sender, address: "bcrt1qoriginal", amountSats: sender.amount,
                                    satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false,
                                    followupContext: .init(feeSats: 143, feeRate: 1, tags: ["original"], contact: nil, createdAt: 100))
        let original = try XCTUnwrap(store.snapshot().first)
        sender.txid = String(repeating: "da", count: 32)
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

    @MainActor
    func testReceivedTransferPublishesExactResolutionForVisiblePending() async throws {
        let confirmed = Bitkit.LightningService.shared.onchainTransactionConfirmed
        let received = Bitkit.LightningService.shared.onchainTransactionReceived
        defer {
            Bitkit.LightningService.shared.onchainTransactionConfirmed = confirmed
            Bitkit.LightningService.shared.onchainTransactionReceived = received
        }
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        let service = OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false })
        let order = IBtOrder.mock(id: "original-order")
        let recoveryReady = expectation(description: "Recovered original order resumes funding setup")
        var balanceRefreshes = 0
        let vm = TransferViewModel(
            transferService: makeService(), sheetViewModel: SheetViewModel(),
            onBalanceRefresh: { balanceRefreshes += 1; recoveryReady.fulfill() },
            onchainAttemptService: service, onchainSender: node, onchainBalanceProvider: { 10000 }
        )
        vm.onOrderCreated(order: order)
        do { try await vm.payOrder(order: order, speed: .normal, txFee: 123, satsPerVbyte: 2) } catch {}
        XCTAssertNil(vm.recoveredOnchainFundingOrderId)
        XCTAssertEqual(balanceRefreshes, 0, "Unknown funding must not advance setup")
        let unrelatedStore = MemoryAttemptStore()
        let unrelatedNode = AttemptNodeMock(result: .unknown(txid: String(repeating: "cd", count: 32)))
        var unrelatedRefreshes = 0
        let unrelatedVM = TransferViewModel(
            transferService: makeService(), sheetViewModel: SheetViewModel(),
            onBalanceRefresh: { unrelatedRefreshes += 1 },
            onchainAttemptService: OnchainSendAttemptService(store: unrelatedStore, hasPaidOrder: { _ in false }),
            onchainSender: unrelatedNode, onchainBalanceProvider: { 10000 }
        )
        do {
            try await unrelatedVM.payOrder(order: .mock(id: "other-order"), speed: .normal, txFee: 123, satsPerVbyte: 2)
        } catch {}
        let original = try XCTUnwrap(store.snapshot().first)
        let wallet = makeWallet(attempts: service)
        let resolutionReady = expectation(description: "Visible Pending receives exact durable transfer resolution")
        var resolved: OnchainSendLocalResolution?
        let observation = OnchainSendAttemptService.localResolutionPublisher.sink { resolution in
            if resolution.attemptId == original.id, resolution.walletId == original.walletId, resolution.txid == txid, resolved == nil {
                resolved = resolution
                resolutionReady.fulfill()
            }
        }
        defer { observation.cancel() }
        await Bitkit.LightningService.shared.onchainTransactionReceived?(txid)
        await fulfillment(of: [resolutionReady, recoveryReady], timeout: 2)
        XCTAssertEqual(vm.recoveredOnchainFundingOrderId, order.id)
        XCTAssertEqual(balanceRefreshes, 1)
        XCTAssertNil(unrelatedVM.recoveredOnchainFundingOrderId)
        XCTAssertEqual(unrelatedRefreshes, 0)
        XCTAssertEqual(unrelatedNode.calls, 1)
        await Bitkit.LightningService.shared.onchainTransactionReceived?(txid)
        XCTAssertEqual(balanceRefreshes, 1, "A delayed repeat event must not resume order setup twice")
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, true)
        XCTAssertEqual(resolved?.activity.txId, txid, "Pending Details must refer to the actual winning funding transaction")
        XCTAssertEqual(resolved?.activity.isTransfer, true)
        if let resolved {
            let context = OnchainSendPendingContext(attemptId: original.id, walletId: original.walletId, txid: original.txid)
            XCTAssertTrue(SendPendingScreen.matchesLocalResolution(resolved, attempt: original, context: context, walletId: "new-selected-wallet"))
            XCTAssertFalse(SendPendingScreen.matchesLocalResolution(resolved, attempt: original,
                                                                    context: .init(attemptId: UUID(), walletId: original.walletId, txid: txid),
                                                                    walletId: original.walletId))
            XCTAssertFalse(SendPendingScreen.matchesLocalResolution(resolved, attempt: original,
                                                                    context: .init(attemptId: original.id, walletId: "other-wallet", txid: txid),
                                                                    walletId: original.walletId))
            let reopened = try await service.resolvedAcceptedTransfer(context: context, using: makeService())
            XCTAssertEqual(reopened?.txid, txid, "Resolution preceding Pending initialization must still enable exact Details")
        }
        XCTAssertEqual(node.calls, 1)
        withExtendedLifetime(wallet) {}
    }

    @MainActor
    func testUnknownOrderFundingOpensExactPendingWithoutFinishingSetup() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        let sheets = SheetViewModel()
        let order = IBtOrder.mock()
        let vm = TransferViewModel(
            transferService: makeService(), sheetViewModel: sheets,
            onchainAttemptService: OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false }),
            onchainSender: node, onchainBalanceProvider: { 50000 }
        )
        do {
            try await vm.payOrder(order: order, speed: .normal, txFee: 123, satsPerVbyte: 2)
            XCTFail("Unknown funding must not finish setup")
        } catch {}
        let original = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(original.orderId, order.id)
        XCTAssertTrue(original.blocksNewSend)
        XCTAssertTrue(try Bitkit.TransferStorage(defaults: transferDefaults).getAll().isEmpty)
        XCTAssertEqual(node.calls, 1)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
        let config = try XCTUnwrap(sheets.activeSheetConfiguration?.data as? SendConfig)
        guard case let .onchainPending(context) = config.initialRoute else {
            return XCTFail("Funding lost the exact original Pending route")
        }
        XCTAssertEqual(context.attemptId, original.id)
        XCTAssertEqual(context.walletId, original.walletId)
        XCTAssertEqual(context.txid, txid)
    }

    @MainActor
    func testDismissedFundingPendingReopensWithoutCreatingOrSendingAnotherOrder() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        let sheets = SheetViewModel()
        let order = IBtOrder.mock()
        let vm = TransferViewModel(
            transferService: makeService(), sheetViewModel: sheets,
            onchainAttemptService: OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false }),
            onchainSender: node, onchainBalanceProvider: { 50000 }
        )
        vm.onOrderCreated(order: order)
        do { try await vm.payOrder(order: order, speed: .normal, txFee: 123, satsPerVbyte: 2) } catch {}
        let original = try XCTUnwrap(store.snapshot().first)
        sheets.hideSheet()
        do {
            _ = try await vm.orderForSwipe { _, _ in
                XCTFail("An unresolved funding operation must not create a new order")
                return IBtOrder.mock(id: "replacement-order")
            }
            XCTFail("The reset swipe must yield to original Pending")
        } catch is OnchainFundingPendingError {} catch { XCTFail("Wrong funding re-entry error: \(error)") }
        let config = try XCTUnwrap(sheets.activeSheetConfiguration?.data as? SendConfig)
        guard case let .onchainPending(context) = config.initialRoute else { return XCTFail("Missing Pending") }
        XCTAssertEqual(context.attemptId, original.id)
        XCTAssertEqual(context.walletId, original.walletId)
        XCTAssertEqual(context.txid, txid)
        XCTAssertEqual(node.calls, 1)
    }

    @MainActor
    func testRejectedOrderFundingOpensExactPendingWithoutFinishingSetup() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .rejected(txid: txid, reason: "fixture refusal"))
        let sheets = SheetViewModel()
        let order = IBtOrder.mock()
        let vm = TransferViewModel(
            transferService: makeService(), sheetViewModel: sheets,
            onchainAttemptService: OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false }),
            onchainSender: node, onchainBalanceProvider: { 50000 }
        )
        do {
            try await vm.payOrder(order: order, speed: .normal, txFee: 123, satsPerVbyte: 2)
            XCTFail("Rejected funding must not finish setup")
        } catch {}
        let original = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(original.orderId, order.id)
        XCTAssertTrue(original.blocksNewSend)
        XCTAssertTrue(try Bitkit.TransferStorage(defaults: transferDefaults).getAll().isEmpty)
        XCTAssertEqual(node.calls, 1)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
        let config = try XCTUnwrap(sheets.activeSheetConfiguration?.data as? SendConfig)
        guard case let .onchainPending(context) = config.initialRoute else {
            return XCTFail("Funding lost the exact original Pending route")
        }
        XCTAssertEqual(context.attemptId, original.id)
        XCTAssertEqual(context.walletId, original.walletId)
        XCTAssertEqual(context.txid, txid)
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
    func testAcceptedIncompleteFundingReopensExpiredOriginalAndRepairsWithoutBroadcast() async throws {
        let store = MemoryAttemptStore()
        let txid = String(repeating: "ab", count: 32)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let attempts = OnchainSendAttemptService(store: store, hasPaidOrder: { _ in false })
        let sheets = SheetViewModel()
        let order = IBtOrder.mock()
        let vm = TransferViewModel(transferService: makeService(), sheetViewModel: sheets,
                                  onchainAttemptService: attempts, onchainSender: node, onchainBalanceProvider: { 50000 })
        vm.onOrderCreated(order: order)
        transferDefaults.set(Data("broken-transfer-store".utf8), forKey: "transfers")
        do { try await vm.payOrder(order: order, speed: .normal, txFee: 123, satsPerVbyte: 2) } catch {}
        let original = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(original.status, .accepted)
        XCTAssertFalse(original.localFollowupComplete)
        sheets.hideSheet()
        do {
            _ = try await vm.orderForSwipe { _, _ in
                XCTFail("Accepted incomplete funding must retain the expired original order")
                return IBtOrder.mock(id: "replacement-order")
            }
            XCTFail("Incomplete accepted funding must reopen Pending")
        } catch is OnchainFundingPendingError {} catch { XCTFail("Wrong error: \(error)") }
        let config = try XCTUnwrap(sheets.activeSheetConfiguration?.data as? SendConfig)
        guard case let .onchainPending(context) = config.initialRoute else { return XCTFail("Missing Pending") }
        XCTAssertEqual(context.attemptId, original.id)
        XCTAssertEqual(context.walletId, original.walletId)
        XCTAssertEqual(context.txid, txid)
        XCTAssertEqual(node.calls, 1)
        transferDefaults.removeObject(forKey: "transfers")
        try await vm.payOrder(order: order, speed: .normal, txFee: 999, satsPerVbyte: 9)
        XCTAssertTrue(try XCTUnwrap(store.snapshot().first).localFollowupComplete)
        XCTAssertEqual(vm.recoveredOnchainFundingOrderId, order.id)
        XCTAssertEqual(node.calls, 1)
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
        let durableActivity = try await activity.getOnchainActivityByTxId(txid: txid)
        let durableTags = try await activity.tags(forActivity: txid)
        XCTAssertEqual(durableActivity?.address, "bcrt1qoriginal")
        XCTAssertEqual(durableTags, ["saved-tag"])
        XCTAssertEqual(durableActivity?.feeRate, 2)
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

    func testConcurrentPaidOrderFollowupCreatesOneOriginalRecord() async throws {
        let storage = ConcurrentPaidOrderStorage(defaults: transferDefaults)
        let service = Bitkit.TransferService(
            storage: storage, lightningService: .shared, blocktankService: Bitkit.CoreService.shared.blocktank,
            isGeoBlocked: { false }
        )
        let txid = String(repeating: "ab", count: 32)
        let first = Task.detached {
            try await service.createTransfer(type: .toSpending, amountSats: 1000, fundingTxId: txid,
                                             lspOrderId: "concurrent-paid-order", txTotalSats: 1100, preTransferOnchainSats: 9000)
        }
        await fulfillment(of: [storage.firstLookup], timeout: 5)
        let second = Task.detached {
            try await service.createTransfer(type: .toSpending, amountSats: 9999, fundingTxId: txid,
                                             lspOrderId: "concurrent-paid-order", txTotalSats: 9999, preTransferOnchainSats: 9999)
        }
        let firstId = try await first.value
        let secondId = try await second.value
        XCTAssertEqual(firstId, secondId, "Concurrent original-operation follow-up created two record identities")
        let records = try storage.getAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.fundingTxId, txid)
        XCTAssertEqual(records.first?.amountSats, 1000)
        XCTAssertEqual(records.first?.txTotalSats, 1100)
        XCTAssertEqual(records.first?.preTransferOnchainSats, 9000)
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

private final class ConcurrentPaidOrderStorage: Bitkit.TransferStorage {
    let firstLookup = XCTestExpectation(description: "Original paid-order lookup captured")
    private let lock = NSLock()
    private let secondLookup = DispatchSemaphore(value: 0)
    private var lookupCount = 0

    override func getAll() throws -> [Bitkit.Transfer] {
        let snapshot = try super.getAll()
        lock.lock()
        lookupCount += 1
        let index = lookupCount
        lock.unlock()
        if index == 1 {
            firstLookup.fulfill()
            _ = secondLookup.wait(timeout: .now() + 2)
        } else if index == 2 {
            secondLookup.signal()
        }
        return snapshot
    }
}
