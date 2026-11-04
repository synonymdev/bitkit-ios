import BitkitCore
import Combine
import Foundation
import LDKNode

protocol OnchainSending {
    var currentWalletIndex: Int { get }
    var onchainDispatchNode: AnyObject? { get }
    func prepareOnchainSend(address: String, sats: UInt64, satsPerVbyte: UInt32,
                            utxosToSpend: [SpendableUtxo]?, isMaxAmount: Bool,
                            expectedWalletIndex: Int, expectedNode: AnyObject?, paymentDeadline: PaykitPreciseInstant?) async throws
        -> PreparedOnchainSendDispatch
    func newAddress() async throws -> String
    func walletSpends(of inputs: [OnchainSendInput], expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> [OnchainInputSpend]
    /// Replaces the wallet's own unconfirmed transaction `txid` with one at `satsPerVbyte` (RBF), and returns its ID.
    func bumpFee(ofTransaction txid: String, satsPerVbyte: UInt32, expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> String
}

extension LightningService: OnchainSending {
    func prepareOnchainSend(
        address: String, sats: UInt64, satsPerVbyte: UInt32,
        utxosToSpend: [SpendableUtxo]?, isMaxAmount: Bool,
        expectedWalletIndex: Int, expectedNode: AnyObject?, paymentDeadline: PaykitPreciseInstant?
    ) async throws -> PreparedOnchainSendDispatch {
        guard let node = onchainDispatchNode as? Node else { throw NodeError.NotRunning(message: "Node not set up") }
        let (prepared, txid, inputs, recipientAmountSats, miningFeeSats) = try await ServiceQueue.background(.ldk, wrapErrors: false) {
            guard self.currentWalletIndex == expectedWalletIndex, self.onchainDispatchNode === node, expectedNode === node else {
                throw NodeError.NotRunning(message: "Wallet or node changed before on-chain preparation")
            }
            try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline)
            let prepared: PreparedOnchainSend = if isMaxAmount {
                try node.onchainPayment().prepareSendAllToAddress(
                    address: address, retainReserves: true,
                    feeRate: .fromSatPerKwu(satKwu: max(UInt64(satsPerVbyte) * 250, 253))
                )
            } else {
                try node.onchainPayment().prepareSendToAddress(
                    address: address, amountSats: sats,
                    feeRate: .fromSatPerKwu(satKwu: max(UInt64(satsPerVbyte) * 250, 253)), utxosToSpend: utxosToSpend
                )
            }
            return (prepared, prepared.txid(), prepared.inputs().map { OnchainSendInput(txid: $0.txid, vout: $0.vout) },
                    prepared.recipientAmountSats(), prepared.miningFeeSats())
        }
        return PreparedOnchainSendDispatch(
            txid: txid, inputs: inputs, recipientAmountSats: recipientAmountSats, miningFeeSats: miningFeeSats,
            broadcast: {
                try await ServiceQueue.background(.ldk, wrapErrors: false) {
                    do {
                        guard self.currentWalletIndex == expectedWalletIndex, self.onchainDispatchNode === node, expectedNode === node else {
                            throw NodeError.NotRunning(message: "Wallet or node changed before on-chain dispatch")
                        }
                        try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline)
                    } catch {
                        throw PreparedOnchainSendNotSubmitted(underlying: error)
                    }
                    return try prepared.broadcast()
                }
            }
        )
    }

    /// Reads spends of `inputs` from the node wallet's own history, never from a backend or mempool query.
    func walletSpends(of inputs: [OnchainSendInput], expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> [OnchainInputSpend]
    {
        guard let node = onchainDispatchNode as? Node else { throw NodeError.NotRunning(message: "Node not set up") }
        return try await ServiceQueue.background(.ldk, wrapErrors: false) {
            guard self.currentWalletIndex == expectedWalletIndex, self.onchainDispatchNode === node, expectedNode === node else {
                throw NodeError.NotRunning(message: "Wallet or node changed before reading on-chain spends")
            }
            return node.listPayments().compactMap { payment in
                guard case let .onchain(txid, _) = payment.kind, let details = node.getTransactionDetails(txid: txid) else { return nil }
                return OnchainInputSpend(payment: payment, details: details, guarding: inputs) { node.getTransactionDetails(txid: $0) }
            }
        }
    }

    func bumpFee(ofTransaction txid: String, satsPerVbyte: UInt32, expectedWalletIndex: Int, expectedNode: AnyObject?) async throws
        -> String
    {
        guard let node = onchainDispatchNode as? Node else { throw NodeError.NotRunning(message: "Node not set up") }
        return try await ServiceQueue.background(.ldk, wrapErrors: false) {
            guard self.currentWalletIndex == expectedWalletIndex, self.onchainDispatchNode === node, expectedNode === node else {
                throw NodeError.NotRunning(message: "Wallet or node changed before an on-chain fee bump")
            }
            return try node.onchainPayment().bumpFeeByRbf(
                txid: txid, feeRate: .fromSatPerKwu(satKwu: max(UInt64(satsPerVbyte) * 250, 253))
            )
        }
    }
}

/// The wallet side of cancelling a payment: proving that none of its transactions reached the network, and spending
/// its coins back to the wallet so that none of them can confirm later.
protocol OnchainReleasing {
    func onchainCandidatesNeverReachedNetwork(_ attempt: OnchainSendAttempt) async throws -> Bool
    func walletKnowsTransaction(_ txid: String) async -> Bool
    /// Whether a transaction that is not a candidate already spent one of the original's coins.
    func originalCoinSpentElsewhere(_ attempt: OnchainSendAttempt) async throws -> Bool
    /// The wallet's own transactions that spend one of the original's coins.
    func originalCoinSpends(_ attempt: OnchainSendAttempt) async throws -> [OnchainInputSpend]
    func prepareRelease(_ attempt: OnchainSendAttempt) async throws -> PreparedOnchainSendDispatch
}

extension LightningService: OnchainReleasing {
    /// The release pays a small fixed amount to a new wallet address; the rest of the coins return as change, so the
    /// fee comes out of the whole input value however small the payment was.
    static let releaseAmountSats: UInt64 = 1000

    /// Two syncs over a slow Electrum server can take well over a minute, and a check that runs out of time only fails closed.
    func onchainCandidatesNeverReachedNetwork(_ attempt: OnchainSendAttempt) async throws -> Bool {
        try await onchainCandidatesNeverReachedNetwork(attempt, syncTimeout: .seconds(120))
    }

    func originalCoinSpentElsewhere(_ attempt: OnchainSendAttempt) async throws -> Bool {
        guard let original = attempt.recoveryContext?.inputs, !original.isEmpty else { return false }
        let spendable = try await Set(listSpendableOutputs().map { OnchainSendInput(txid: $0.outpoint.txid, vout: $0.outpoint.vout) })
        return original.contains { !spendable.contains($0) }
    }

    func originalCoinSpends(_ attempt: OnchainSendAttempt) async throws -> [OnchainInputSpend] {
        guard let original = attempt.recoveryContext?.inputs, !original.isEmpty else { return [] }
        return try await walletSpends(of: original, expectedWalletIndex: currentWalletIndex, expectedNode: onchainDispatchNode)
    }

    func walletKnowsTransaction(_ txid: String) async -> Bool {
        guard let node = onchainDispatchNode as? Node else { return false }
        return await (try? ServiceQueue.background(.ldk, wrapErrors: false) { node.getTransactionDetails(txid: txid) != nil }) ?? false
    }

    /// Spends the original's coins back to the wallet at a fee above every candidate's, so the release replaces any
    /// copy of the original a node still holds, and no candidate can confirm once it does.
    func prepareRelease(_ attempt: OnchainSendAttempt) async throws -> PreparedOnchainSendDispatch {
        guard attempt.walletId == OnchainSendAttemptService.walletId(index: currentWalletIndex),
              let recovery = attempt.recoveryContext, !recovery.inputs.isEmpty
        else { throw OnchainSendAttemptError.retryUnavailable }
        let original = Set(recovery.inputs)
        let confirmedTxids = await Set(listPayments()?.compactMap { payment -> String? in
            guard case let .onchain(txid, .confirmed) = payment.kind else { return nil }
            return txid
        } ?? [])
        let inputSets = try await OnchainSendAttemptService.releaseInputSets(
            spendable: listSpendableOutputs(), original: original, confirmedTxids: confirmedTxids
        )
        guard let originalCount = inputSets.first?.count else { throw OnchainSendAttemptError.retryUnavailable }
        let address = try await newAddress()
        var lastError: Error = OnchainSendAttemptError.retryConstruction
        for utxos in inputSets {
            var feeRate = max(recovery.satsPerVbyte, recovery.candidateFeeRates?.values.max() ?? 0) + 2
            for _ in 0 ..< 4 {
                let prepared: PreparedOnchainSendDispatch
                do {
                    prepared = try await prepareOnchainSend(
                        address: address, sats: Self.releaseAmountSats, satsPerVbyte: feeRate, utxosToSpend: utxos,
                        isMaxAmount: false, expectedWalletIndex: currentWalletIndex, expectedNode: onchainDispatchNode,
                        paymentDeadline: nil
                    )
                } catch {
                    // These coins cannot fund the release at this fee; try the next, larger set.
                    lastError = error
                    break
                }
                // Every spendable original coin must go, so no candidate can still confirm.
                guard Set(utxos.prefix(originalCount).map { OnchainSendInput(txid: $0.outpoint.txid, vout: $0.outpoint.vout) })
                    .isSubset(of: prepared.inputs)
                else { throw OnchainSendAttemptError.retryConstruction }
                if OnchainSendAttemptService.releaseOutbids(prepared, attempt) {
                    // A Cancel payment over the same coins must pay a higher rate than the release.
                    var release = prepared
                    release.satsPerVbyte = feeRate
                    return release
                }
                feeRate *= 2
            }
        }
        throw lastError
    }
}

extension LightningService {
    /// Syncs the on-chain wallet, then checks that the wallet knows none of the payment's transactions while it still
    /// knows the transactions its coins came from. A candidate that reached the mempool or the chain spends wallet
    /// coins, so a sync adds it to the wallet.
    func onchainCandidatesNeverReachedNetwork(_ attempt: OnchainSendAttempt, syncTimeout: Duration) async throws -> Bool {
        try await Self.onchainCandidatesNeverReachedNetwork(
            attempt, syncTimeout: syncTimeout, currentWallet: { (self.currentWalletIndex, self.onchainDispatchNode as? Node) },
            sync: { try await self.sync() }
        )
    }

    /// Reads whichever node `currentWallet` runs at the time: a node restarted during the check holds the same wallet, and
    /// reports the timestamp of a sync it ran before the restart, so only one it ran after the request counts. A wallet
    /// without a node, or one switched during the check, leaves no fresh view to check, so the sync is unavailable.
    static func onchainCandidatesNeverReachedNetwork(
        _ attempt: OnchainSendAttempt,
        syncTimeout: Duration,
        pollInterval: Duration = .milliseconds(500),
        currentWallet: @escaping @Sendable () -> (index: Int, node: Node?),
        sync: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        let wallet = currentWallet()
        guard attempt.walletId == OnchainSendAttemptService.walletId(index: wallet.index),
              let inputs = attempt.recoveryContext?.inputs, !inputs.isEmpty
        else { return false }
        guard wallet.node != nil else { throw OnchainSendAbandonError.syncUnavailable }
        try await OnchainSendAttemptService.waitForOnchainSyncAfterRequest(
            timeout: syncTimeout,
            pollInterval: pollInterval,
            latestSync: { currentWallet().node?.status().latestOnchainWalletSyncTimestamp },
            sync: sync
        )
        return try await ServiceQueue.background(.ldk, wrapErrors: false) {
            let wallet = currentWallet()
            guard attempt.walletId == OnchainSendAttemptService.walletId(index: wallet.index), let node = wallet.node else {
                throw OnchainSendAbandonError.syncUnavailable
            }
            guard attempt.candidateTxids.allSatisfy({ node.getTransactionDetails(txid: $0) == nil }) else { return false }
            return inputs.allSatisfy { node.getTransactionDetails(txid: $0.txid) != nil }
        }
    }
}

struct OnchainSendInput: Codable, Equatable, Hashable {
    let txid: String
    let vout: UInt32

    var utxo: SpendableUtxo {
        SpendableUtxo(outpoint: OutPoint(txid: Txid(txid), vout: vout), valueSats: 0)
    }
}

/// A transaction in the node's own wallet history that spends at least one guarded input.
struct OnchainInputSpend: Equatable {
    let txid: String
    let inputs: [OnchainSendInput]
    /// A nil entry is an output without an address, which never proves the recipient went unpaid.
    let outputAddresses: [String?]
    /// Confirmed at the node's anti-reorg depth, so no conflicting candidate can replace it.
    let isFinal: Bool
    /// The value of each output, in the order of `outputAddresses`.
    var outputValues: [UInt64] = []
    /// Exact, from the transactions its coins came from. Nil when the wallet lacks one of them.
    var feeSats: UInt64?
    /// The rate `feeSats` pays on its signed size, rounded up.
    var satsPerVbyte: UInt32?
    /// The node reports it failed, as for a transaction that dropped out of mempools or was replaced.
    var isDropped = false

    /// Every candidate pays its recipient the whole amount in one output.
    func pays(_ address: String, atLeast amountSats: UInt64) -> Bool {
        zip(outputAddresses, outputValues).contains { outputAddress, value in
            outputAddress?.caseInsensitiveCompare(address) == .orderedSame && value >= amountSats
        }
    }
}

extension OnchainInputSpend {
    /// LDK reports an on-chain payment succeeded only once its transaction is ANTI_REORG_DELAY blocks deep. The payment's own
    /// fee reads zero when the node cannot work it out, so the fee is worked out from `previous`, the wallet's transactions.
    init?(
        payment: LDKNode.PaymentDetails, details: LDKNode.TransactionDetails, guarding inputs: [OnchainSendInput],
        previous: (String) -> LDKNode.TransactionDetails?
    ) {
        guard case let .onchain(txid, status) = payment.kind else { return nil }
        let guarded = Set(inputs.map { OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout) })
        let spent = details.inputs.map { OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout) }
        guard spent.contains(where: guarded.contains) else { return nil }
        let isConfirmed = if case .confirmed = status {
            true
        } else {
            false
        }
        // A fee that cannot be worked out exactly stays unknown, which only ever keeps a spend from being taken as a payment.
        let feeSats = try? OnchainSendLocalFollowup.exactFee(details: details, previous: previous)
        self.init(
            txid: txid.lowercased(), inputs: spent, outputAddresses: details.outputs.map(\.scriptpubkeyAddress),
            isFinal: isConfirmed && payment.status == .succeeded,
            outputValues: details.outputs.map { UInt64(clamping: $0.value) },
            feeSats: feeSats,
            satsPerVbyte: feeSats.map { UInt32(clamping: details.feeRate(paying: $0)) },
            isDropped: payment.status == .failed
        )
    }
}

/// Produced only by the adapter before entering the native broadcast call.
struct PreparedOnchainSendNotSubmitted: Error {
    let underlying: Error
}

struct PreparedOnchainSendDispatch {
    let txid: String
    let inputs: [OnchainSendInput]
    let recipientAmountSats: UInt64
    var miningFeeSats: UInt64?
    /// The rate it was prepared at, when known. The rate it pays can only be higher.
    var satsPerVbyte: UInt32?
    let broadcast: () async throws -> OnchainSendResult
}

struct OnchainSendRecoveryContext: Codable, Equatable {
    let inputs: [OnchainSendInput]
    let satsPerVbyte: UInt32
    let paymentIdentity: String?
    var candidateTxids: [String]
    var candidateFeeRates: [String: UInt32]? = nil
    var candidateFeeSats: [String: UInt64]? = nil

    func feeRate(for txid: String) -> UInt32? {
        if let rate = candidateFeeRates?[txid.lowercased()] {
            return rate > 0 ? rate : nil
        }
        return candidateTxids.first?.caseInsensitiveCompare(txid) == .orderedSame ? satsPerVbyte : nil
    }
}

enum OnchainSendAttemptError: LocalizedError, CustomStringConvertible {
    case unresolved
    case blocked(OnchainSendAttempt?)
    case duplicate
    case outcomeNotSaved
    case localFollowupNotSaved
    case retryConstruction
    case retryUnavailable
    case preDispatch(Error)
    case preDispatchCleanupFailed

    var description: String {
        errorDescription ?? t("wallet__onchain_send_unresolved")
    }

    var errorDescription: String? {
        switch self {
        case .unresolved, .blocked:
            t("wallet__onchain_send_unresolved")
        case .duplicate:
            t("wallet__onchain_send_duplicate")
        case .outcomeNotSaved:
            t("wallet__onchain_outcome_save_failed")
        case .localFollowupNotSaved, .preDispatchCleanupFailed:
            t("wallet__onchain_followup_failed")
        case .retryConstruction:
            t("wallet__onchain_retry_construction")
        case .retryUnavailable:
            t("wallet__onchain_retry_unavailable")
        case let .preDispatch(error):
            error.localizedDescription
        }
    }
}

/// A Cancel payment replaces every transaction over the same coins a node may hold: each candidate, a release and an earlier
/// Cancel payment. So it must pay more in all than the highest of them, by at least its own size, and at a higher rate (BIP125
/// rules 3, 4 and 6).
struct OnchainCancellationFeeTooLowError: LocalizedError {
    let requiredFeeSats: UInt64
    /// The highest rate that is still refused: every higher one is enough.
    let feeRate: UInt32

    var errorDescription: String? {
        t("wallet__onchain_cancel_fee_too_low", variables: ["fee": CurrencyFormatter.formatSats(requiredFeeSats)])
    }
}

/// The original payment's request is already reported paid, so it is not sent again.
struct OnchainOriginalPaidError: LocalizedError {
    var errorDescription: String? {
        t("wallet__onchain_resend_paid")
    }
}

enum OnchainSendAbandonError: LocalizedError {
    case requestOpen
    case mayStillConfirm
    case syncUnavailable
    case releasePending

    var errorDescription: String? {
        switch self {
        case .requestOpen, .mayStillConfirm:
            t("wallet__onchain_abandon_refused")
        case .syncUnavailable:
            t("wallet__onchain_abandon_sync")
        case .releasePending:
            t("wallet__onchain_abandon_pending")
        }
    }
}

struct OnchainSendAttempt: Codable, Equatable {
    enum Status: String, Codable {
        case pending
        case accepted
        case rejected
        case unknown

        var blocksNewSend: Bool {
            self != .accepted
        }
    }

    let id: UUID
    let walletId: String
    let requestId: PaykitPaymentRequest.ID?
    let orderId: String?
    let address: String
    var amountSats: UInt64
    let isMaxAmount: Bool
    var status: Status
    var txid: String? = nil
    var rejectionReason: String? = nil
    var localFollowupComplete = false
    var followupContext: OnchainSendFollowupContext? = nil
    var transferContext: OnchainSendTransferContext? = nil
    var recoveryContext: OnchainSendRecoveryContext? = nil
    /// Set on an attempt restored from a backup, which may not hold evidence that its transaction was broadcast.
    var restoredFromBackup: Bool? = nil
    /// Set once its request was found ended, so a release cut short after its proof was removed can finish.
    var releaseApproved: Bool? = nil
    /// The transaction spending the original's coins back to the wallet, saved before it is broadcast.
    var releaseTxid: String? = nil
    /// The release's rate and mining fee, which a Cancel payment over the same coins must both outbid.
    var releaseFeeRate: UInt32? = nil
    var releaseFeeSats: UInt64? = nil
    /// The latest Cancel payment, saved before it is broadcast, with the rate and fee a replacement must outbid.
    var cancellationTxid: String? = nil
    var cancellationFeeRate: UInt32? = nil
    var cancellationFeeSats: UInt64? = nil

    /// A release or Cancel payment may have reached the network, so a retry beside it could replace it.
    var mayHaveRelayedCancellation: Bool {
        releaseTxid != nil || cancellationTxid != nil
    }

    var blocksNewSend: Bool {
        status.blocksNewSend || !localFollowupComplete
    }

    func containsCandidate(_ txid: String?) -> Bool {
        guard let txid else { return self.txid == nil }
        return self.txid?.caseInsensitiveCompare(txid) == .orderedSame ||
            recoveryContext?.candidateTxids.contains(where: { $0.caseInsensitiveCompare(txid) == .orderedSame }) == true
    }

    func storedCandidate(_ txid: String) -> String? {
        if self.txid?.caseInsensitiveCompare(txid) == .orderedSame {
            return self.txid
        }
        return recoveryContext?.candidateTxids.first { $0.caseInsensitiveCompare(txid) == .orderedSame }
    }

    var candidateTxids: Set<String> {
        Set(([txid].compactMap { $0 } + (recoveryContext?.candidateTxids ?? [])).map { $0.lowercased() })
    }

    /// A Paykit payment from the node wallet that the network never confirmed accepting. Once its request
    /// has ended and no candidate reached the network, it can be released instead of blocking every send.
    /// A transfer to spending that pays a Blocktank order, which Bitkit no longer buys.
    var isBlocktankFunding: Bool {
        requestId == nil && orderId != nil
    }

    var canBeAbandoned: Bool {
        (requestId != nil && orderId == nil || isBlocktankFunding) && status != .accepted && txid != nil &&
            walletId.hasPrefix("node:") && recoveryContext?.inputs.isEmpty == false
    }

    var canRetrySamePayment: Bool {
        guard status == .pending || status == .unknown || status == .rejected, let recovery = recoveryContext,
              !recovery.inputs.isEmpty, let txid, recovery.candidateTxids.contains(txid)
        else { return false }
        return requestId == nil || recovery.paymentIdentity != nil
    }

    /// Every candidate spends all original inputs and pays `address`, including one a stale backup never recorded.
    /// A spend of any original input that pays nothing to `address` therefore conflicts with all of them unpaid.
    func isCancelled(by spend: OnchainInputSpend) -> Bool {
        guard status != .accepted, let recovery = recoveryContext, !recovery.candidateTxids.isEmpty else { return false }
        let originals = Set(recovery.inputs.map { OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout) })
        return spend.inputs.contains { originals.contains(OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout)) } &&
            !containsCandidate(spend.txid) && !spend.outputAddresses.isEmpty &&
            spend.outputAddresses.allSatisfy { $0.map { $0.caseInsensitiveCompare(address) != .orderedSame } ?? false }
    }

    /// A spend of exactly the original inputs that pays `address` at least the amount in one output is a candidate of this
    /// payment even when none records it, such as a fee bump a restore lost.
    func isUnrecordedCandidate(_ spend: OnchainInputSpend) -> Bool {
        guard status != .accepted, let recovery = recoveryContext, !recovery.inputs.isEmpty, !containsCandidate(spend.txid)
        else { return false }
        let originals = recovery.inputs.map { OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout) }
        let spent = spend.inputs.map { OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout) }
        return spent.count == originals.count && Set(spent) == Set(originals) && spend.pays(address, atLeast: amountSats)
    }
}

struct OnchainSendFollowupContext: Codable, Equatable {
    var feeSats: UInt64
    var feeRate: UInt32
    let tags: [String]
    let contact: String?
    let createdAt: UInt64
    var backupCreatedAtMillis: UInt64? = nil
    var channelId: String? = nil
}

struct OnchainSendTransferContext: Codable, Equatable {
    let clientBalanceSats: UInt64
    let txTotalSats: UInt64
    let preTransferOnchainSats: UInt64
    var originalOrderFeeSats: UInt64? = nil
}

struct OnchainSendLocalResolution {
    let attemptId: UUID
    let walletId: String
    let txid: String
    let amountSats: UInt64
    let contact: String?
    let activity: OnchainActivity
}

protocol OnchainSendLocalFollowupHandling {
    func save(_ attempt: OnchainSendAttempt) async throws -> OnchainActivity
}

struct OnchainSendLocalFollowup: OnchainSendLocalFollowupHandling {
    static func observedFee(_ attempt: OnchainSendAttempt) async throws -> UInt64? {
        let service = LightningService.shared
        guard attempt.walletId == OnchainSendAttemptService.walletId(index: service.currentWalletIndex),
              let node = service.onchainDispatchNode as? Node, let txid = attempt.txid
        else {
            throw OnchainSendAttemptError.localFollowupNotSaved
        }
        return try await ServiceQueue.background(.ldk, wrapErrors: false) {
            guard attempt.walletId == OnchainSendAttemptService.walletId(index: service.currentWalletIndex),
                  service.onchainDispatchNode === node,
                  let details = node.getTransactionDetails(txid: txid) else { return nil }
            guard Set(details.inputs.map { OnchainSendInput(txid: $0.txid, vout: $0.vout) }) == Set(attempt.recoveryContext?.inputs ?? []) else {
                throw OnchainSendAttemptError.localFollowupNotSaved
            }
            return try exactFee(details: details, previous: { node.getTransactionDetails(txid: $0) })
        }
    }

    static func exactFee(details: LDKNode.TransactionDetails,
                         previous: (String) -> LDKNode.TransactionDetails?) throws -> UInt64?
    {
        var inputTotal: UInt64 = 0
        var outputTotal: UInt64 = 0
        guard !details.inputs.isEmpty,
              Set(details.inputs.map { OnchainSendInput(txid: $0.txid, vout: $0.vout) }).count == details.inputs.count
        else { throw OnchainSendAttemptError.localFollowupNotSaved }
        for input in details.inputs {
            guard let parent = previous(input.txid) else { return nil }
            let outputs = parent.outputs.filter { $0.n == input.vout }
            guard outputs.count == 1, let value = outputs.first?.value, value >= 0,
                  !inputTotal.addingReportingOverflow(UInt64(value)).overflow
            else {
                throw OnchainSendAttemptError.localFollowupNotSaved
            }
            inputTotal += UInt64(value)
        }
        for output in details.outputs {
            guard output.value >= 0, !outputTotal.addingReportingOverflow(UInt64(output.value)).overflow else {
                throw OnchainSendAttemptError.localFollowupNotSaved
            }
            outputTotal += UInt64(output.value)
        }
        guard inputTotal >= outputTotal else { throw OnchainSendAttemptError.localFollowupNotSaved }
        return inputTotal - outputTotal
    }

    func save(_ attempt: OnchainSendAttempt) async throws -> OnchainActivity {
        guard let txid = attempt.txid, attempt.status == .accepted else { throw OnchainSendAttemptError.localFollowupNotSaved }
        let activity = CoreService.shared.activity
        if let context = attempt.followupContext {
            try await activity.upsertPreActivityMetadata([BitkitCore.PreActivityMetadata(
                walletId: WalletScope.default, paymentId: txid, tags: context.tags, paymentHash: nil,
                txId: txid, address: attempt.address, isReceive: false, feeRate: UInt64(context.feeRate),
                isTransfer: false, channelId: nil, createdAt: context.createdAt
            )])
            guard await activity.createSentOnchainActivityFromSendResult(
                txid: txid, address: attempt.address, amount: attempt.amountSats,
                fee: context.feeSats, feeRate: context.feeRate, contact: context.contact,
                feeIsExact: attempt.recoveryContext.map { $0.candidateTxids.first?.caseInsensitiveCompare(txid) != .orderedSame } ?? false,
                // Retrying an unacknowledged save must preserve later contact edits, including removal.
                preserveExistingContact: true
            ) else { throw OnchainSendAttemptError.localFollowupNotSaved }
        } else {
            guard let metadata = try await activity.getPreActivityMetadata(searchKey: txid),
                  metadata.paymentId.caseInsensitiveCompare(txid) == .orderedSame,
                  metadata.txId?.caseInsensitiveCompare(txid) == .orderedSame
            else { throw OnchainSendAttemptError.localFollowupNotSaved }
        }
        guard let saved = try await activity.getOnchainActivityByTxId(txid: txid),
              saved.txId.caseInsensitiveCompare(txid) == .orderedSame, saved.txType == .sent
        else { throw OnchainSendAttemptError.localFollowupNotSaved }
        return saved
    }
}

protocol OnchainSendAttemptStoring: Sendable {
    func load() throws -> [OnchainSendAttempt]
    func save(_ attempts: [OnchainSendAttempt]) throws
}

struct OnchainSendAttemptStore: OnchainSendAttemptStoring {
    private static let backupDataChanged = PassthroughSubject<Void, Never>()
    static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        backupDataChanged.eraseToAnyPublisher()
    }

    func load() throws -> [OnchainSendAttempt] {
        guard let data = try Keychain.load(key: .onchainSendAttempts) else { return [] }
        return try JSONDecoder().decode([OnchainSendAttempt].self, from: data)
    }

    func save(_ attempts: [OnchainSendAttempt]) throws {
        try Keychain.upsert(key: .onchainSendAttempts, data: JSONEncoder().encode(attempts))
        Self.backupDataChanged.send()
    }
}

/// What the wallet's own final spends of an unsettled attempt's inputs showed.
enum OnchainSendWalletSettlement: Equatable {
    /// A spend that pays nothing to the recipient conflicts with every candidate, and released this attempt's guard.
    case cancelled(OnchainSendAttempt)
    /// This candidate is final, and is now the winner.
    case confirmed(txid: String)
}

struct OnchainSendPendingContext: Hashable {
    let attemptId: UUID
    let walletId: String
    let txid: String?
}

actor OnchainSendAttemptService {
    static let shared = OnchainSendAttemptService()

    /// The coin sets a release tries, smallest first: the original's coins alone, then with the wallet's other coins
    /// added one at a time, largest first. A small payment's coins may not cover the release's output and higher fee;
    /// growing one coin at a time stops at the first set that can pay, so dust coins join only when nothing smaller would.
    /// Only confirmed coins join the original's: nodes holding a candidate refuse a replacement that adds an unconfirmed
    /// input (BIP125 rule 2), and an unconfirmed parent can still be replaced or evicted.
    static func releaseInputSets(
        spendable: [SpendableUtxo], original: Set<OnchainSendInput>, confirmedTxids: Set<String>
    ) -> [[SpendableUtxo]] {
        let isOriginal = { (utxo: SpendableUtxo) in original.contains(OnchainSendInput(txid: utxo.outpoint.txid, vout: utxo.outpoint.vout)) }
        let originals = spendable.filter(isOriginal)
        guard !originals.isEmpty else { return [] }
        let others = spendable.filter { !isOriginal($0) && confirmedTxids.contains($0.outpoint.txid) }.sorted { $0.valueSats > $1.valueSats }
        // Each set starts with every original coin, so a release spends them all.
        return (0 ... others.count).map { originals + others.prefix($0) }
    }

    /// A release must spend at least one of the original's coins, and pay more than any candidate, so it replaces a
    /// candidate a node may still hold.
    static func releaseOutbids(_ prepared: PreparedOnchainSendDispatch, _ attempt: OnchainSendAttempt) -> Bool {
        guard let recovery = attempt.recoveryContext, let fee = prepared.miningFeeSats,
              !Set(recovery.inputs).isDisjoint(with: prepared.inputs)
        else { return false }
        return fee > highestCandidateFee(attempt)
    }

    /// A backup without per-candidate fees still bounds a retry's fee: it spends the same coins to the same output, so it has
    /// the original's size at its own rate.
    static func highestCandidateFee(_ attempt: OnchainSendAttempt) -> UInt64 {
        guard let recovery = attempt.recoveryContext else { return 0 }
        let originalFee = attempt.followupContext?.feeSats ?? 0
        let originalRate = UInt64(max(recovery.satsPerVbyte, 1))
        let scaledFee = (recovery.candidateFeeRates?.values.max()).map {
            originalFee.saturatingMultiply(UInt64($0)).saturatingAdd(originalRate - 1) / originalRate
        } ?? 0
        return max(recovery.candidateFeeSats?.values.max() ?? 0, originalFee, scaledFee)
    }

    /// The highest fee and rate among the transactions over the original's coins that a Cancel payment replaces.
    static func replacedFee(_ attempt: OnchainSendAttempt) -> (feeSats: UInt64, satsPerVbyte: UInt32) {
        let candidateRate = attempt.recoveryContext.map { max($0.candidateFeeRates?.values.max() ?? 0, $0.satsPerVbyte) } ?? 0
        let releaseFee = attempt.releaseTxid == nil ? 0 : attempt.releaseFeeSats ?? 0
        let releaseRate = attempt.releaseTxid == nil ? 0 : attempt.releaseFeeRate ?? 0
        let cancellationFee = attempt.cancellationTxid == nil ? 0 : attempt.cancellationFeeSats ?? 0
        let cancellationRate = attempt.cancellationTxid == nil ? 0 : attempt.cancellationFeeRate ?? 0
        return (max(highestCandidateFee(attempt), releaseFee, cancellationFee), max(candidateRate, releaseRate, cancellationRate))
    }

    /// The least a Cancel payment paying `feeSats` at `satsPerVbyte` must pay to replace a transaction that paid `releaseFeeSats`:
    /// more than it, by at least its own size at the 1 sat/vB incremental relay fee (BIP125 rules 3 and 4). Its fee is rounded
    /// up, so the fee over the rate, rounded up, is at least its size.
    static func cancellationFeeFloor(releaseFeeSats: UInt64, feeSats: UInt64, satsPerVbyte: UInt32) -> UInt64 {
        let rate = UInt64(max(satsPerVbyte, 1))
        return releaseFeeSats.saturatingAdd(feeSats / rate + (feeSats.isMultiple(of: rate) ? 0 : 1))
    }

    /// The highest rate at which a transaction paying `feeSats` at `satsPerVbyte` pays no more than `targetFeeSats`. Its fee is
    /// rounded up, so its size is above (`feeSats` - 1) / `satsPerVbyte`, and every higher rate pays more.
    static func highestFeeRate(notAbove targetFeeSats: UInt64, feeSats: UInt64, satsPerVbyte: UInt32) -> UInt32 {
        UInt32(clamping: targetFeeSats.saturatingMultiply(UInt64(satsPerVbyte)) / max(feeSats.saturatingSub(1), 1))
    }

    /// A sync known to have started after a check's request proves a fresh view once it succeeds. Otherwise only a sync that
    /// finished later than `previous`, read once no sync from before the request can still run, counts; one finished in the
    /// same second may predate that read, and without `previous` none counts.
    static func isOnchainSync(_ latest: UInt64?, after previous: UInt64?, requestedSyncSucceeded: Bool = false) -> Bool {
        requestedSyncSucceeded || previous.map { (latest ?? 0) > $0 } ?? false
    }

    /// Waits for an on-chain sync that started after this call, or throws `OnchainSendAbandonError.syncUnavailable` once
    /// `timeout` passes. ldk-node joins a wallet sync already under way, which may have started before the call, and returns
    /// once it completes. So only a sync after a successful first one counts: the second requested sync, or one that finishes
    /// later than the sync `latestSync` reads once the first returned. A first sync that fails may never have joined the
    /// earlier one, which may still finish, and a missing reading sets no baseline at all.
    static func waitForOnchainSyncAfterRequest(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(500),
        latestSync: @escaping @Sendable () -> UInt64?,
        sync: @escaping @Sendable () async throws -> Void
    ) async throws {
        let requestedSync = RequestedSyncResult()
        // The sync blocks in native code and ignores cancellation, so it runs apart and the wait keeps its limit. Once the
        // wait has ended, the second sync is not started.
        Task {
            do {
                try await sync()
                if let baseline = latestSync() {
                    await requestedSync.setBaseline(baseline)
                }
                guard await !requestedSync.isWaitOver else { return }
                try await sync()
                await requestedSync.markSucceeded()
            } catch {
                Logger.warn("Requested on-chain sync failed: \(error)", context: "OnchainSendAttempt")
            }
        }
        do {
            let deadline = ContinuousClock.now + timeout
            while await !isOnchainSync(latestSync(), after: requestedSync.baseline, requestedSyncSucceeded: requestedSync.succeeded) {
                guard ContinuousClock.now < deadline else { throw OnchainSendAbandonError.syncUnavailable }
                try await Task.sleep(for: pollInterval)
            }
        } catch {
            await requestedSync.endWait()
            throw error
        }
        await requestedSync.endWait()
    }

    static func walletId(index: Int) -> String {
        "node:\(Env.networkName):\(WalletScope.default):\(index)"
    }

    private static let localResolutionSubject = PassthroughSubject<OnchainSendLocalResolution, Never>()

    nonisolated static var localResolutionPublisher: AnyPublisher<OnchainSendLocalResolution, Never> {
        localResolutionSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    private static let cancellationReleaseSubject = PassthroughSubject<UUID, Never>()

    /// The ID of each attempt released after a final cancellation. Stored, so a view's `onReceive` keeps one subscription
    /// across body evaluations.
    static let cancellationReleasePublisher = cancellationReleaseSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()

    private let localFollowup: any OnchainSendLocalFollowupHandling
    private let winningFee: (OnchainSendAttempt) async throws -> UInt64?
    private let store: any OnchainSendAttemptStoring
    private var knownAttempt: OnchainSendAttempt?
    private var nativeDispatchInProgress: UUID?
    private var isBroadcastingCancellation = false
    private var cancellationBroadcastWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestFollowupInProgress: UUID?
    private var ordinaryFollowupInProgress: UUID?

    init(
        store: any OnchainSendAttemptStoring = OnchainSendAttemptStore(),
        localFollowup: any OnchainSendLocalFollowupHandling = OnchainSendLocalFollowup(),
        winningFee: @escaping (OnchainSendAttempt) async throws -> UInt64? = OnchainSendLocalFollowup.observedFee
    ) {
        self.localFollowup = localFollowup
        self.winningFee = winningFee
        self.store = store
    }

    func backupSnapshot(wallet: PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet,
                        proofs: [PendingPaykitPaymentProof]) throws -> PaykitPaymentStateBackup.ActiveOnchainAttempt?
    {
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.unresolved }
        guard let attempt = try currentAttempt(), attempt.blocksNewSend else { return nil }
        if attempt.status == .pending, attempt.txid == nil,
           attempt.recoveryContext?.inputs.isEmpty != false,
           attempt.recoveryContext?.candidateTxids.isEmpty != false
        {
            throw OnchainSendAttemptError.unresolved
        }
        let billingPeriod = proofs.first {
            $0.requestId == attempt.requestId && $0.identity == attempt.recoveryContext?.paymentIdentity
        }?.billingPeriod
        let wire = try PaykitPaymentStateBackup.ActiveOnchainAttempt(attempt, wallet: wallet, billingPeriod: billingPeriod)
        _ = try wire.restored(wallet: wallet, proofs: proofs)
        return wire
    }

    func restoreBackup(_ attempt: OnchainSendAttempt?) throws {
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.unresolved }
        if var previous = try currentAttempt(), previous.blocksNewSend {
            // A restore must not erase a newer unresolved candidate or another original operation.
            guard var incoming = attempt else { throw OnchainSendAttemptError.unresolved }
            // Exact fee evidence is local and absent from the shared backup record.
            previous.recoveryContext?.candidateFeeSats = nil
            incoming.recoveryContext?.candidateFeeSats = nil
            previous.restoredFromBackup = nil
            // A local release approval and its transaction are not part of the shared backup record.
            previous.releaseApproved = nil
            previous.releaseTxid = nil
            previous.releaseFeeRate = nil
            previous.releaseFeeSats = nil
            previous.cancellationTxid = nil
            previous.cancellationFeeRate = nil
            previous.cancellationFeeSats = nil
            // The backup stamps its own follow-up time, which the live attempt never stores.
            previous.followupContext?.backupCreatedAtMillis = nil
            incoming.followupContext?.backupCreatedAtMillis = nil
            guard previous == incoming else { throw OnchainSendAttemptError.unresolved }
            return
        }
        var restored = attempt
        restored?.restoredFromBackup = true
        try store.save(restored.map { [$0] } ?? [])
        knownAttempt = restored
    }

    func send(
        using lightningService: any OnchainSending,
        address: String,
        amountSats: UInt64,
        satsPerVbyte: UInt32,
        utxosToSpend: [SpendableUtxo]?,
        isMaxAmount: Bool,
        requestId: PaykitPaymentRequest.ID? = nil,
        orderId: String? = nil,
        paymentIdentity: String? = nil,
        followupContext: OnchainSendFollowupContext? = nil,
        transferContext: OnchainSendTransferContext? = nil,
        paymentDeadline: PaykitPreciseInstant? = nil,
        beforeBroadcastAttempt: () async throws -> Void = {},
        onPreDispatchFailure: (Error) async throws -> Void = { _ in throw OnchainSendAttemptError.preDispatchCleanupFailed }
    ) async throws -> OnchainSendResult {
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.blocked(try? currentAttempt()) }
        let walletIndex = lightningService.currentWalletIndex
        let dispatchNode = lightningService.onchainDispatchNode
        if let prior = try currentAdmissionAttempt(), prior.status == .accepted, let txid = prior.txid,
           prior.walletId == Self.walletId(index: walletIndex),
           prior.recoveryContext?.paymentIdentity == nil || prior.recoveryContext?.paymentIdentity == paymentIdentity,
           (requestId != nil && prior.requestId == requestId) || (orderId != nil && prior.orderId == orderId)
        {
            return .accepted(txid: txid)
        }
        let attemptId = try admit(
            walletId: Self.walletId(index: walletIndex),
            requestId: requestId,
            orderId: orderId,
            address: address,
            amountSats: amountSats,
            isMaxAmount: isMaxAmount,
            followupContext: followupContext,
            transferContext: transferContext
        )
        nativeDispatchInProgress = attemptId
        defer { nativeDispatchInProgress = nil }
        let prepared: PreparedOnchainSendDispatch
        do {
            prepared = try await lightningService.prepareOnchainSend(
                address: address, sats: amountSats, satsPerVbyte: satsPerVbyte,
                utxosToSpend: utxosToSpend, isMaxAmount: isMaxAmount,
                expectedWalletIndex: walletIndex, expectedNode: dispatchNode, paymentDeadline: paymentDeadline
            )
            do {
                try validateReceipt(prepared, amount: isMaxAmount && requestId == nil ? nil : amountSats,
                                    inputs: isMaxAmount ? nil : utxosToSpend?
                                        .map { OnchainSendInput(txid: $0.outpoint.txid, vout: $0.outpoint.vout) })
                guard var attempt = try currentAttempt(), attempt.id == attemptId else { throw OnchainSendAttemptError.unresolved }
                if orderId != nil && isMaxAmount {
                    guard let context = attempt.transferContext,
                          let originalFee = context.originalOrderFeeSats,
                          let miningFee = prepared.miningFeeSats,
                          miningFee <= context.txTotalSats,
                          prepared.recipientAmountSats >= originalFee,
                          prepared.recipientAmountSats <= context.txTotalSats - miningFee
                    else { throw OnchainSendAttemptError.unresolved }
                }
                attempt.amountSats = prepared.recipientAmountSats
                attempt.txid = prepared.txid
                if let miningFee = prepared.miningFeeSats {
                    attempt.followupContext?.feeSats = miningFee
                }
                attempt.recoveryContext = OnchainSendRecoveryContext(
                    inputs: prepared.inputs, satsPerVbyte: satsPerVbyte, paymentIdentity: paymentIdentity,
                    candidateTxids: [prepared.txid], candidateFeeRates: [prepared.txid.lowercased(): satsPerVbyte],
                    candidateFeeSats: prepared.miningFeeSats.map { [prepared.txid.lowercased(): $0] }
                )
                try store.save([attempt])
                knownAttempt = attempt
            }
            try await beforeBroadcastAttempt()
            try checkWallet(lightningService, index: walletIndex, node: dispatchNode)
        } catch {
            if case OnchainSendAttemptError.preDispatchCleanupFailed = error {
                throw OnchainSendAttemptError.unresolved
            }
            let preDispatchError = error
            do { try clearBeforeDispatch(attemptId: attemptId) }
            catch { throw OnchainSendAttemptError.unresolved }
            throw OnchainSendAttemptError.preDispatch(preDispatchError)
        }

        if let winner = try winningResult(attemptId: attemptId) {
            return winner
        }
        let result: OnchainSendResult
        // Once broadcast starts, any thrown error is ambiguous. Never release its receipt.
        do { result = try await normalized(prepared.broadcast(), candidate: prepared.txid) }
        catch let failure as PreparedOnchainSendNotSubmitted {
            // Remove the exact durable proof before releasing its matching wallet guard.
            do {
                if requestId != nil {
                    try await onPreDispatchFailure(failure.underlying)
                }
                try clearBeforeDispatch(attemptId: attemptId)
            } catch {
                throw OnchainSendAttemptError.unresolved
            }
            throw OnchainSendAttemptError.preDispatch(failure.underlying)
        } catch { result = .unknown(txid: prepared.txid) }

        do {
            try record(result, attemptId: attemptId)
        } catch {
            Logger.warn("Could not persist the known on-chain outcome; the durable attempt still blocks another send", context: "OnchainSendAttempt")
        }
        return (try? winningResult(attemptId: attemptId)) ?? result
    }

    func retrySamePayment(
        using sender: any OnchainSending, context: OnchainSendPendingContext, satsPerVbyte: UInt32? = nil,
        paymentDeadline: PaykitPreciseInstant? = nil,
        approvePrepared: (PreparedOnchainSendDispatch) async throws -> Void = { _ in },
        authorize: (OnchainSendAttempt, UInt32) async throws -> Void
    ) async throws -> OnchainSendResult {
        // A release or Cancel payment that may have been relayed could be replaced by a retry, so none is sent beside it.
        guard nativeDispatchInProgress == nil, let original = try currentAttempt(),
              original.id == context.attemptId, original.walletId == context.walletId,
              original.containsCandidate(context.txid), original.canRetrySamePayment, !original.mayHaveRelayedCancellation,
              let recovery = original.recoveryContext
        else { throw OnchainSendAttemptError.unresolved }
        let index = sender.currentWalletIndex
        let node = sender.onchainDispatchNode
        guard original.walletId == Self.walletId(index: index) else { throw OnchainSendAttemptError.unresolved }
        nativeDispatchInProgress = original.id
        defer { nativeDispatchInProgress = nil }
        let authorizedFeeRate = satsPerVbyte ?? recovery.satsPerVbyte
        guard authorizedFeeRate > 0, authorizedFeeRate <= 999 else { throw OnchainSendAttemptError.unresolved }
        // Send-all already spends the original inputs minus its fee. A bump cannot
        // preserve both the exact input set and the original recipient amount.
        guard !original.isMaxAmount || authorizedFeeRate == recovery.satsPerVbyte else {
            throw OnchainSendAttemptError.retryConstruction
        }
        try checkWallet(sender, index: index, node: node)
        if let winner = try winningResult(attemptId: original.id) {
            return winner
        }
        let prepared: PreparedOnchainSendDispatch
        do {
            let receipt = try await sender.prepareOnchainSend(
                address: original.address, sats: original.amountSats, satsPerVbyte: authorizedFeeRate,
                utxosToSpend: recovery.inputs.map(\.utxo), isMaxAmount: false,
                expectedWalletIndex: index, expectedNode: node, paymentDeadline: paymentDeadline
            )
            prepared = receipt
            do { try validateReceipt(prepared, amount: original.amountSats, inputs: recovery.inputs) }
            catch { throw OnchainSendAttemptError.retryConstruction }
        } catch let error as NodeError {
            switch error {
            case .InsufficientFunds, .OnchainTxCreationFailed, .InvalidAmount, .WalletOperationFailed:
                throw OnchainSendAttemptError.retryConstruction
            default: throw OnchainSendAttemptError.retryUnavailable
            }
        } catch let error as OnchainSendAttemptError { throw error }
        catch { throw OnchainSendAttemptError.retryUnavailable }
        try checkWallet(sender, index: index, node: node)
        if let winner = try winningResult(attemptId: original.id) {
            return winner
        }
        guard var attempt = try currentAttempt(), attempt.id == original.id,
              attempt.recoveryContext == recovery, !attempt.mayHaveRelayedCancellation
        else { throw OnchainSendAttemptError.unresolved }
        let addedCandidate = !attempt.containsCandidate(prepared.txid)
        if addedCandidate {
            attempt.recoveryContext?.candidateTxids.append(prepared.txid)
        }
        if let previousRate = attempt.recoveryContext?.candidateFeeRates?[prepared.txid.lowercased()],
           previousRate != authorizedFeeRate
        {
            throw OnchainSendAttemptError.unresolved
        }
        if attempt.recoveryContext?.candidateFeeRates == nil {
            attempt.recoveryContext?.candidateFeeRates = [:]
            if let originalTxid = recovery.candidateTxids.first {
                attempt.recoveryContext?.candidateFeeRates?[originalTxid.lowercased()] = recovery.satsPerVbyte
            }
        }
        attempt.recoveryContext?.candidateFeeRates?[prepared.txid.lowercased()] = authorizedFeeRate
        if let fee = prepared.miningFeeSats {
            if let retained = attempt.recoveryContext?.candidateFeeSats?[prepared.txid.lowercased()], retained != fee {
                throw OnchainSendAttemptError.unresolved
            }
            if attempt.recoveryContext?.candidateFeeSats == nil {
                attempt.recoveryContext?.candidateFeeSats = [:]
            }
            attempt.recoveryContext?.candidateFeeSats?[prepared.txid.lowercased()] = fee
        }
        // Keep the original rejected/unknown state until a real new outcome arrives.
        // A crash here still recognizes both possible payments and cannot unlock the wallet.
        try store.save([attempt])
        knownAttempt = attempt
        // One authorization, after preparation and immediately before native dispatch.
        // It validates the original payer/request/order and the chosen fee policy without
        // repeating initial proof-start/consume side effects.
        do {
            try Task.checkCancellation()
            try await approvePrepared(prepared)
            try Task.checkCancellation()
            try await authorize(attempt, authorizedFeeRate)
            try Task.checkCancellation()
            try checkWallet(sender, index: index, node: node)
            if let winner = try winningResult(attemptId: original.id) {
                try discardUnsubmittedRetryCandidate(prepared.txid, attemptId: original.id, wasAdded: addedCandidate)
                return winner
            }
        } catch {
            // The native dispatch closure has not been entered. Remove only the new
            // candidate from this retry; earlier submitted candidates remain guarded.
            do { try discardUnsubmittedRetryCandidate(prepared.txid, attemptId: original.id, wasAdded: addedCandidate) }
            catch { throw OnchainSendAttemptError.unresolved }
            throw error
        }
        let result: OnchainSendResult
        do { result = try await normalized(prepared.broadcast(), candidate: prepared.txid) }
        catch let failure as PreparedOnchainSendNotSubmitted {
            do {
                try discardUnsubmittedRetryCandidate(prepared.txid, attemptId: original.id, wasAdded: addedCandidate)
            } catch {
                throw OnchainSendAttemptError.unresolved
            }
            if let winner = try winningResult(attemptId: original.id) {
                return winner
            }
            throw OnchainSendAttemptError.preDispatch(failure.underlying)
        } catch {
            result = .unknown(txid: prepared.txid)
        }
        do { try record(result, attemptId: original.id) }
        catch { Logger.warn("Could not persist the known recovery outcome; original inputs remain guarded", context: "OnchainSendAttempt") }
        return (try? winningResult(attemptId: original.id)) ?? result
    }

    /// Spends the exact original inputs back to this wallet, conflicting with every candidate without paying anyone.
    /// The guard is left as it is until that spend is final, through `settleFromWallet`.
    func cancelOriginalPayment(
        using sender: any OnchainSending, context: OnchainSendPendingContext, satsPerVbyte: UInt32,
        approvePrepared: (PreparedOnchainSendDispatch) async throws -> Void = { _ in },
        authorize: () async throws -> Void
    ) async throws -> OnchainSendResult {
        guard nativeDispatchInProgress == nil, let original = try currentAttempt(),
              original.id == context.attemptId, original.walletId == context.walletId,
              original.containsCandidate(context.txid), original.canRetrySamePayment,
              let recovery = original.recoveryContext
        else { throw OnchainSendAttemptError.unresolved }
        let index = sender.currentWalletIndex
        let node = sender.onchainDispatchNode
        guard original.walletId == Self.walletId(index: index), satsPerVbyte > 0, satsPerVbyte <= 999 else {
            throw OnchainSendAttemptError.unresolved
        }
        nativeDispatchInProgress = original.id
        defer { nativeDispatchInProgress = nil }
        // Both outputs stay in this wallet: a dust-limit output to a fresh address plus change. Unlike a sweep, this
        // stays within the node's spendable-balance and anchor-reserve checks for any original input set.
        let address = try await sender.newAddress()
        try checkWallet(sender, index: index, node: node)
        guard address.caseInsensitiveCompare(original.address) != .orderedSame else { throw OnchainSendAttemptError.unresolved }
        let prepared = try await sender.prepareOnchainSend(
            address: address, sats: UInt64(Env.dustLimit), satsPerVbyte: satsPerVbyte,
            utxosToSpend: recovery.inputs.map(\.utxo), isMaxAmount: false,
            expectedWalletIndex: index, expectedNode: node, paymentDeadline: nil
        )
        try validateReceipt(prepared, amount: UInt64(Env.dustLimit), inputs: recovery.inputs)
        guard !original.containsCandidate(prepared.txid) else { throw OnchainSendAttemptError.unresolved }
        try Self.checkOutbids(prepared, replacing: original, satsPerVbyte: satsPerVbyte)
        try Task.checkCancellation()
        try await approvePrepared(prepared)
        try Task.checkCancellation()
        try await authorize()
        try Task.checkCancellation()
        try checkWallet(sender, index: index, node: node)
        // A candidate that gained positive evidence meanwhile may still confirm, so it is never conflicted with.
        guard var current = try currentAttempt(), current.id == original.id, current.status != .accepted,
              current.recoveryContext?.inputs == recovery.inputs
        else { throw OnchainSendAttemptError.unresolved }
        try Self.checkOutbids(prepared, replacing: current, satsPerVbyte: satsPerVbyte)
        // Saved before the broadcast, so a reopened Pending, a retry or a release knows it may have been relayed.
        let earlier = (txid: current.cancellationTxid, feeRate: current.cancellationFeeRate, feeSats: current.cancellationFeeSats)
        current.cancellationTxid = prepared.txid.lowercased()
        current.cancellationFeeRate = satsPerVbyte
        current.cancellationFeeSats = prepared.miningFeeSats
        try store.save([current])
        knownAttempt = current
        isBroadcastingCancellation = true
        defer { endCancellationBroadcast() }
        let result: OnchainSendResult
        do { result = try await normalized(prepared.broadcast(), candidate: prepared.txid) }
        catch let failure as PreparedOnchainSendNotSubmitted {
            restoreEarlierCancellation(replacing: prepared.txid, with: earlier)
            throw OnchainSendAttemptError.preDispatch(failure.underlying)
        } catch {
            return .unknown(txid: prepared.txid)
        }
        if case .rejected = result {
            // Refused by the node it was sent to, so it never reached the network.
            restoreEarlierCancellation(replacing: prepared.txid, with: earlier)
        }
        return result
    }

    private static func checkOutbids(_ prepared: PreparedOnchainSendDispatch, replacing attempt: OnchainSendAttempt, satsPerVbyte: UInt32) throws {
        let replaced = replacedFee(attempt)
        var refusedRate = satsPerVbyte > replaced.satsPerVbyte ? 0 : replaced.satsPerVbyte
        if replaced.feeSats > 0 {
            guard let fee = prepared.miningFeeSats else { throw OnchainSendAttemptError.retryUnavailable }
            let floor = cancellationFeeFloor(releaseFeeSats: replaced.feeSats, feeSats: fee, satsPerVbyte: satsPerVbyte)
            if fee < floor {
                refusedRate = max(refusedRate, highestFeeRate(notAbove: floor - 1, feeSats: fee, satsPerVbyte: satsPerVbyte))
            }
        }
        guard refusedRate == 0 else {
            throw OnchainCancellationFeeTooLowError(requiredFeeSats: replaced.feeSats, feeRate: refusedRate)
        }
    }

    private func restoreEarlierCancellation(
        replacing txid: String, with earlier: (txid: String?, feeRate: UInt32?, feeSats: UInt64?)
    ) {
        do {
            guard var current = try currentAttempt(), current.cancellationTxid == txid.lowercased() else { return }
            current.cancellationTxid = earlier.txid
            current.cancellationFeeRate = earlier.feeRate
            current.cancellationFeeSats = earlier.feeSats
            try store.save([current])
            knownAttempt = current
        } catch {
            // The refused cancellation stays recorded, which only keeps retries hidden.
            Logger.warn("Could not clear a refused cancellation \(txid): \(error)", context: "OnchainSendAttempt")
        }
    }

    private func endCancellationBroadcast() {
        isBroadcastingCancellation = false
        let waiters = cancellationBroadcastWaiters
        cancellationBroadcastWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func waitForCancellationBroadcast() async {
        while isBroadcastingCancellation {
            await withCheckedContinuation { cancellationBroadcastWaiters.append($0) }
        }
    }

    /// Replaces the wallet's unconfirmed Cancel payment with the same spend at a higher rate (RBF), when the wallet holds it and
    /// so cannot build another spend of the same coins. Every output of a Cancel payment is this wallet's, so the replacement
    /// still pays the recipient nothing. ldk-node builds and broadcasts it in one call, so it is saved once sent; the
    /// cancellation it replaces is saved already, so no retry or release is offered meanwhile.
    func speedUpCancellation(
        using sender: any OnchainSending, context: OnchainSendPendingContext, satsPerVbyte: UInt32,
        authorize: () async throws -> Void
    ) async throws -> String {
        guard nativeDispatchInProgress == nil, let original = try currentAttempt(),
              original.id == context.attemptId, original.walletId == context.walletId,
              original.containsCandidate(context.txid), original.canRetrySamePayment,
              let recovery = original.recoveryContext
        else { throw OnchainSendAttemptError.unresolved }
        let index = sender.currentWalletIndex
        let node = sender.onchainDispatchNode
        guard original.walletId == Self.walletId(index: index), satsPerVbyte > 0, satsPerVbyte <= 999 else {
            throw OnchainSendAttemptError.unresolved
        }
        nativeDispatchInProgress = original.id
        defer { nativeDispatchInProgress = nil }
        guard let held = try await cancellation(of: original, using: sender), !held.isFinal else { throw OnchainSendAttemptError.unresolved }
        let heldRate = max(held.satsPerVbyte ?? 0, Self.replacedFee(original).satsPerVbyte)
        guard satsPerVbyte > heldRate else {
            throw OnchainCancellationFeeTooLowError(requiredFeeSats: held.feeSats ?? 0, feeRate: heldRate)
        }
        try Task.checkCancellation()
        try await authorize()
        try Task.checkCancellation()
        try checkWallet(sender, index: index, node: node)
        guard let current = try currentAttempt(), current.id == original.id, current.status != .accepted,
              current.recoveryContext?.inputs == recovery.inputs
        else { throw OnchainSendAttemptError.unresolved }
        isBroadcastingCancellation = true
        defer { endCancellationBroadcast() }
        let txid = try await sender.bumpFee(
            ofTransaction: held.txid, satsPerVbyte: satsPerVbyte, expectedWalletIndex: index, expectedNode: node
        ).lowercased()
        if var latest = try currentAttempt(), latest.id == original.id {
            latest.cancellationTxid = txid
            latest.cancellationFeeRate = satsPerVbyte
            // ldk-node does not report the replacement's fee, so a later Cancel payment outbids its rate and the other fees.
            latest.cancellationFeeSats = nil
            try store.save([latest])
            knownAttempt = latest
        }
        Logger.info("Sped up cancellation \(held.txid) of on-chain send \(original.id) as \(txid)", context: "OnchainSendAttempt")
        return txid
    }

    /// The wallet's own spend that cancels `attempt`, final or still confirming, if one exists: a final one first, then the
    /// recorded Cancel payment. One that dropped out no longer holds the coins, so a new Cancel payment can be built.
    func cancellation(of attempt: OnchainSendAttempt, using sender: any OnchainSending) async throws -> OnchainInputSpend? {
        let index = sender.currentWalletIndex
        guard attempt.walletId == Self.walletId(index: index) else { throw OnchainSendAttemptError.unresolved }
        guard let inputs = attempt.recoveryContext?.inputs, !inputs.isEmpty else { return nil }
        let cancellations = try await sender.walletSpends(of: inputs, expectedWalletIndex: index, expectedNode: sender.onchainDispatchNode)
            .filter(attempt.isCancelled(by:))
        let held = cancellations.filter { !$0.isDropped }
        return cancellations.first(where: \.isFinal) ??
            held.first { $0.txid.caseInsensitiveCompare(attempt.cancellationTxid ?? "") == .orderedSame } ?? held.first
    }

    /// Settles an unsettled guard from the wallet's own final spends of its inputs, read once. It is released only on positive
    /// evidence that no candidate can ever confirm: a final spend of an original input that pays nothing to the recipient.
    /// Rejection, expiry or mempool absence never do. A final candidate is settled as the winner, for when no confirmation
    /// event reaches the attempt. So is a final spend of exactly the original inputs that pays the recipient, which no
    /// candidate records when a restore lost it, once its exact fee is known.
    func settleFromWallet(
        using sender: any OnchainSending, removeOriginalProof: (OnchainSendAttempt) async -> Bool
    ) async throws -> OnchainSendWalletSettlement? {
        guard nativeDispatchInProgress == nil, let attempt = try currentAttempt(), attempt.status != .accepted,
              attempt.walletId == Self.walletId(index: sender.currentWalletIndex),
              let inputs = attempt.recoveryContext?.inputs, !inputs.isEmpty
        else { return nil }
        let finalSpends = try await sender.walletSpends(of: inputs, expectedWalletIndex: sender.currentWalletIndex,
                                                        expectedNode: sender.onchainDispatchNode).filter(\.isFinal)
        guard nativeDispatchInProgress == nil, try currentAttempt() == attempt else { return nil }
        if let spend = finalSpends.first(where: attempt.isCancelled(by:)) {
            return try await releaseCancelled(attempt, by: spend, removeOriginalProof: removeOriginalProof).map { .cancelled($0) }
        }
        if let winner = finalSpends.lazy.compactMap({ attempt.storedCandidate($0.txid) }).first {
            return try await observeConfirmedTransaction(txid: winner) ? .confirmed(txid: winner) : nil
        }
        guard let payment = finalSpends.first(where: attempt.isUnrecordedCandidate),
              try adoptFinalCandidate(attempt, spend: payment)
        else { return nil }
        let txid = payment.txid.lowercased()
        guard try await observeConfirmedTransaction(txid: txid) else { return nil }
        Logger.info("Settled on-chain send \(attempt.id) by unrecorded final payment \(txid)", context: "OnchainSendAttempt")
        return .confirmed(txid: txid)
    }

    private func adoptFinalCandidate(_ expected: OnchainSendAttempt, spend: OnchainInputSpend) throws -> Bool {
        guard nativeDispatchInProgress == nil, var attempt = try currentAttempt(), attempt == expected,
              attempt.isUnrecordedCandidate(spend), var recovery = attempt.recoveryContext
        else { return false }
        let txid = spend.txid.lowercased()
        // Its activity and backup record the fee and rate it paid, so it is never adopted with an estimate.
        guard let fee = spend.feeSats, let rate = spend.satsPerVbyte, rate > 0 else {
            Logger.warn("Not adopting final payment \(txid) of on-chain send \(attempt.id) without its exact fee", context: "OnchainSendAttempt")
            return false
        }
        recovery.candidateTxids.append(txid)
        recovery.candidateFeeRates = (recovery.candidateFeeRates ?? [:]).merging([txid: rate]) { _, adopted in adopted }
        recovery.candidateFeeSats = (recovery.candidateFeeSats ?? [:]).merging([txid: fee]) { _, adopted in adopted }
        attempt.recoveryContext = recovery
        try store.save([attempt])
        knownAttempt = attempt
        return true
    }

    private func releaseCancelled(
        _ attempt: OnchainSendAttempt, by spend: OnchainInputSpend, removeOriginalProof: (OnchainSendAttempt) async -> Bool
    ) async throws -> OnchainSendAttempt? {
        nativeDispatchInProgress = attempt.id
        defer { nativeDispatchInProgress = nil }
        // The unproven proof goes first, so a failure leaves the guard holding its request.
        guard await removeOriginalProof(attempt), try currentAttempt() == attempt, attempt.isCancelled(by: spend) else { return nil }
        try store.save([])
        knownAttempt = nil
        Logger.info("Released on-chain send \(attempt.id) after final cancellation \(spend.txid)", context: "OnchainSendAttempt")
        Self.cancellationReleaseSubject.send(attempt.id)
        return attempt
    }

    private func discardUnsubmittedRetryCandidate(_ txid: String, attemptId: UUID, wasAdded: Bool) throws {
        guard wasAdded else { return }
        guard var current = try currentAttempt(), current.id == attemptId, var recovery = current.recoveryContext else {
            throw OnchainSendAttemptError.unresolved
        }
        guard current.containsCandidate(txid) else { return }
        // Never overwrite an accepted winner or remove an earlier submitted candidate.
        guard !(current.status == .accepted && current.txid?.caseInsensitiveCompare(txid) == .orderedSame),
              recovery.candidateTxids.count > 1,
              recovery.candidateTxids.first?.caseInsensitiveCompare(txid) != .orderedSame
        else { return }
        recovery.candidateTxids.removeAll { $0.caseInsensitiveCompare(txid) == .orderedSame }
        recovery.candidateFeeRates?.removeValue(forKey: txid.lowercased())
        recovery.candidateFeeSats?.removeValue(forKey: txid.lowercased())
        current.recoveryContext = recovery
        try store.save([current])
        knownAttempt = current
    }

    private func checkWallet(_ sender: any OnchainSending, index: Int, node: AnyObject?) throws {
        guard sender.currentWalletIndex == index, sender.onchainDispatchNode === node else {
            throw NodeError.NotRunning(message: "Wallet or node changed before on-chain dispatch")
        }
    }

    private func validateReceipt(_ prepared: PreparedOnchainSendDispatch, amount: UInt64?, inputs: [OnchainSendInput]?) throws {
        guard prepared.txid.count == 64, prepared.txid.allSatisfy(\.isHexDigit),
              prepared.recipientAmountSats > 0, amount == nil || amount == prepared.recipientAmountSats,
              !prepared.inputs.isEmpty, Set(prepared.inputs).count == prepared.inputs.count,
              prepared.inputs.allSatisfy({ $0.txid.count == 64 && $0.txid.allSatisfy(\.isHexDigit) }),
              inputs == nil || (Set(inputs ?? []) == Set(prepared.inputs) && inputs?.count == prepared.inputs.count)
        else { throw OnchainSendAttemptError.unresolved }
    }

    private func normalized(_ result: OnchainSendResult, candidate: String) -> OnchainSendResult {
        switch result {
        case let .accepted(txid) where txid == candidate: return result
        case let .rejected(txid, _) where txid == candidate: return result
        case let .unknown(txid) where txid == candidate: return result
        default: return .unknown(txid: candidate)
        }
    }

    private func winningResult(attemptId: UUID) throws -> OnchainSendResult? {
        guard let attempt = try currentAttempt(), attempt.id == attemptId, attempt.status == .accepted, let txid = attempt.txid
        else { return nil }
        return .accepted(txid: txid)
    }

    func admit(
        walletId: String,
        requestId: PaykitPaymentRequest.ID?,
        orderId: String?,
        address: String,
        amountSats: UInt64,
        isMaxAmount: Bool,
        followupContext: OnchainSendFollowupContext? = nil,
        transferContext: OnchainSendTransferContext? = nil
    ) throws -> UUID {
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.blocked(try? currentAttempt()) }
        if let previous = try currentAdmissionAttempt() {
            guard !previous.blocksNewSend else {
                throw OnchainSendAttemptError.blocked(previous)
            }
            guard !(requestId != nil && previous.requestId == requestId),
                  !(orderId != nil && previous.orderId == orderId)
            else { throw OnchainSendAttemptError.duplicate }
        }
        let attempt = OnchainSendAttempt(
            id: UUID(),
            walletId: walletId,
            requestId: requestId,
            orderId: orderId,
            address: address,
            amountSats: amountSats,
            isMaxAmount: isMaxAmount,
            status: .pending,
            followupContext: followupContext,
            transferContext: transferContext
        )
        try store.save([attempt])
        knownAttempt = attempt
        return attempt.id
    }

    func record(_ result: OnchainSendResult, attemptId: UUID) throws {
        guard var attempt = try knownAttempt ?? currentAttempt(), attempt.id == attemptId else {
            throw OnchainSendAttemptError.outcomeNotSaved
        }
        if attempt.status == .accepted {
            return
        }
        if attempt.recoveryContext == nil {
            guard attempt.status == .pending else { throw OnchainSendAttemptError.outcomeNotSaved }
        } else {
            let txid: String = switch result {
            case let .accepted(id), let .unknown(id), let .rejected(id, _): id
            }
            guard attempt.containsCandidate(txid) else { throw OnchainSendAttemptError.outcomeNotSaved }
        }
        switch result {
        case let .accepted(txid):
            attempt.status = .accepted
            attempt.txid = txid
        case let .rejected(txid, reason):
            attempt.status = .rejected
            attempt.txid = txid
            attempt.rejectionReason = reason
        case let .unknown(txid):
            attempt.status = .unknown
            attempt.txid = txid
        }
        knownAttempt = attempt
        guard try store.load().first?.id == attemptId else { throw OnchainSendAttemptError.outcomeNotSaved }
        try store.save([attempt])
    }

    private func currentAdmissionAttempt() throws -> OnchainSendAttempt? {
        do { return try currentAttempt() }
        catch { throw OnchainSendAttemptError.unresolved }
    }

    private func currentAttempt() throws -> OnchainSendAttempt? {
        let attempts = try store.load()
        guard attempts.count <= 1 else { throw OnchainSendAttemptError.unresolved }
        guard let saved = attempts.first else { return nil }
        if knownAttempt?.id != saved.id, nativeDispatchInProgress == nil,
           saved.status == .pending, saved.txid == nil, saved.recoveryContext == nil
        {
            try store.save([])
            return nil
        }
        return knownAttempt?.id == saved.id ? knownAttempt : saved
    }

    func acknowledgeLocalFollowup(txid: String) throws {
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.unresolved }
        guard var attempt = try currentAttempt(), attempt.status == .accepted,
              attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame
        else { return }
        attempt.localFollowupComplete = true
        try store.save([attempt])
        knownAttempt = attempt
    }

    func resumeAcceptedOrdinarySend(walletId: String, observedTxid: String? = nil,
                                    pendingContext: OnchainSendPendingContext? = nil) async throws -> OnchainSendLocalResolution?
    {
        guard ordinaryFollowupInProgress == nil, var attempt = try currentAttempt(), attempt.walletId == walletId,
              attempt.requestId == nil, attempt.orderId == nil, let txid = attempt.txid
        else { return nil }
        if let pendingContext {
            guard attempt.id == pendingContext.attemptId, attempt.walletId == pendingContext.walletId,
                  attempt.containsCandidate(pendingContext.txid) else { return nil }
        }
        if let observedTxid {
            guard attempt.containsCandidate(observedTxid) else { return nil }
            if attempt.status == .accepted, txid.caseInsensitiveCompare(observedTxid) != .orderedSame {
                return nil
            }
            if attempt.status != .accepted {
                attempt.status = .accepted
                attempt.txid = attempt.storedCandidate(observedTxid)
                knownAttempt = attempt
                try store.save([attempt])
            }
        }
        guard attempt.status == .accepted, nativeDispatchInProgress == nil, let txid = attempt.txid else { return nil }
        if attempt.localFollowupComplete {
            // A delayed native event must not replay metadata/contact writes or publish a new resolution.
            guard observedTxid == nil else { return nil }
            guard let saved = try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid),
                  saved.txId.caseInsensitiveCompare(txid) == .orderedSame, saved.txType == .sent
            else { throw OnchainSendAttemptError.localFollowupNotSaved }
            return OnchainSendLocalResolution(
                attemptId: attempt.id, walletId: walletId, txid: txid, amountSats: saved.value, contact: saved.contact, activity: saved
            )
        }
        ordinaryFollowupInProgress = attempt.id
        defer { ordinaryFollowupInProgress = nil }
        attempt = try await winningFollowupAttempt(attempt)
        let activity = try await localFollowup.save(attempt)
        try acknowledgeLocalFollowup(txid: txid)
        let resolution = OnchainSendLocalResolution(
            attemptId: attempt.id, walletId: walletId, txid: txid, amountSats: activity.value, contact: activity.contact, activity: activity
        )
        Self.localResolutionSubject.send(resolution)
        return resolution
    }

    private func winningFollowupAttempt(_ original: OnchainSendAttempt) async throws -> OnchainSendAttempt {
        guard let recovery = original.recoveryContext, var context = original.followupContext,
              let txid = original.txid else { return original }
        guard let rate = recovery.feeRate(for: txid), rate > 0 else {
            throw OnchainSendAttemptError.localFollowupNotSaved
        }
        let isOriginal = recovery.candidateTxids.first?.caseInsensitiveCompare(txid) == .orderedSame
        let retainedFee = recovery.candidateFeeSats?[txid.lowercased()] ?? (isOriginal && context.feeSats > 0 ? context.feeSats : nil)
        let observed: UInt64? = if let retainedFee {
            retainedFee
        } else {
            try await winningFee(original)
        }
        guard let fee = observed,
              !original.amountSats.addingReportingOverflow(fee).overflow,
              var attempt = try currentAttempt(), attempt.id == original.id,
              attempt.walletId == original.walletId, attempt.status == .accepted, attempt.txid == txid,
              !attempt.localFollowupComplete
        else { throw OnchainSendAttemptError.localFollowupNotSaved }
        context.feeRate = rate
        context.feeSats = fee
        guard context != attempt.followupContext else { return attempt }
        attempt.followupContext = context
        try store.save([attempt])
        knownAttempt = attempt
        return attempt
    }

    func acceptedRequestAttempt() throws -> OnchainSendAttempt? {
        guard nativeDispatchInProgress == nil else { return nil }
        return try currentAttempt().flatMap { $0.requestId != nil && $0.status == .accepted && !$0.localFollowupComplete ? $0 : nil }
    }

    @discardableResult
    func resumeAcceptedRequestSend(requestId: PaykitPaymentRequest.ID, txid: String,
                                   onlyIfIncomplete: Bool = false) async throws -> Bool
    {
        guard nativeDispatchInProgress == nil, requestFollowupInProgress == nil,
              let attempt = try currentAttempt(), attempt.requestId == requestId, attempt.orderId == nil,
              attempt.status == .accepted, attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame
        else { return false }
        if attempt.localFollowupComplete {
            return !onlyIfIncomplete
        }
        // Keep the transition owned across suspending activity/fee operations. A competing
        // reconciliation must neither repeat the write nor publish this call's completion.
        requestFollowupInProgress = attempt.id
        defer { requestFollowupInProgress = nil }
        let winner = try await winningFollowupAttempt(attempt)
        _ = try await localFollowup.save(winner)
        try acknowledgeLocalFollowup(txid: txid)
        return true
    }

    @discardableResult
    func resumeAcceptedTransfer(walletId: String) async throws -> Bool {
        guard nativeDispatchInProgress == nil, let attempt = try currentAttempt(), attempt.walletId == walletId,
              attempt.status == .accepted, attempt.requestId == nil, attempt.orderId != nil, attempt.txid != nil
        else { return false }
        return try await restoreAcceptedTransfer(attempt)
    }

    /// Blocktank no longer opens channels for paid orders, so an accepted funding keeps only its sent activity: no
    /// transfer record is created, and the attempt resolves so later sends are not blocked.
    private func restoreAcceptedTransfer(_ attempt: OnchainSendAttempt) async throws -> Bool {
        guard attempt.orderId != nil, let txid = attempt.txid else { return false }
        guard !attempt.localFollowupComplete else { return true }
        let attempt = try await winningFollowupAttempt(attempt)
        guard let context = attempt.followupContext else {
            throw OnchainSendAttemptError.localFollowupNotSaved
        }
        try await CoreService.shared.activity.upsertPreActivityMetadata([BitkitCore.PreActivityMetadata(
            walletId: WalletScope.default, paymentId: txid, tags: context.tags, paymentHash: nil,
            txId: txid, address: attempt.address, isReceive: false, feeRate: UInt64(context.feeRate),
            isTransfer: true, channelId: nil, createdAt: context.createdAt
        )])
        guard await CoreService.shared.activity.createSentOnchainActivityFromSendResult(
            txid: txid, address: attempt.address, amount: attempt.amountSats, fee: context.feeSats,
            feeRate: context.feeRate, isTransfer: true,
            feeIsExact: attempt.recoveryContext.map { $0.candidateTxids.first?.caseInsensitiveCompare(txid) != .orderedSame } ?? false
        ), let activity = try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid),
        activity.txType == .sent, activity.isTransfer
        else { throw OnchainSendAttemptError.localFollowupNotSaved }
        try acknowledgeLocalFollowup(txid: txid)
        Self.localResolutionSubject.send(OnchainSendLocalResolution(
            attemptId: attempt.id, walletId: attempt.walletId, txid: txid, amountSats: activity.value,
            contact: activity.contact, activity: activity
        ))
        return true
    }

    func resolvedAcceptedTransfer(context: OnchainSendPendingContext) async throws
        -> OnchainSendLocalResolution?
    {
        guard let attempt = try pendingAttempt(context: context), attempt.orderId != nil, attempt.requestId == nil,
              attempt.status == .accepted, let txid = attempt.txid,
              try await restoreAcceptedTransfer(attempt),
              let activity = try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid),
              activity.txType == .sent, activity.isTransfer
        else { return nil }
        return OnchainSendLocalResolution(attemptId: attempt.id, walletId: attempt.walletId, txid: txid,
                                          amountSats: activity.value, contact: activity.contact, activity: activity)
    }

    /// Records that the payment's request has ended, before its release is prepared.
    func approveRelease(_ expected: OnchainSendAttempt) throws -> OnchainSendAttempt {
        guard nativeDispatchInProgress == nil, var attempt = try currentAttempt(), attempt == expected,
              attempt.canBeAbandoned
        else { throw OnchainSendAttemptError.unresolved }
        attempt.releaseApproved = true
        try store.save([attempt])
        knownAttempt = attempt
        return attempt
    }

    /// Saves the release transaction before it is broadcast, so a later cancel can find it in the wallet, and a Cancel payment
    /// knows the rate and fee it must outbid, also after the screen is reopened.
    func recordRelease(_ expected: OnchainSendAttempt, txid: String, feeRate: UInt32?, feeSats: UInt64?) throws -> OnchainSendAttempt {
        guard nativeDispatchInProgress == nil, var attempt = try currentAttempt(), attempt == expected,
              attempt.canBeAbandoned, attempt.releaseApproved == true, !attempt.containsCandidate(txid), attempt.cancellationTxid == nil
        else { throw OnchainSendAttemptError.unresolved }
        attempt.releaseTxid = txid.lowercased()
        attempt.releaseFeeRate = feeRate
        attempt.releaseFeeSats = feeSats
        try store.save([attempt])
        knownAttempt = attempt
        return attempt
    }

    func clearBeforeDispatch(attemptId: UUID) throws {
        var attempts = try store.load()
        guard let index = attempts.firstIndex(where: { $0.id == attemptId && $0.status == .pending }),
              knownAttempt?.id != attemptId || knownAttempt?.status == .pending else { return }
        attempts.remove(at: index)
        try store.save(attempts)
        knownAttempt = nil
    }

    func acceptedRequestContext(requestId: PaykitPaymentRequest.ID, paymentIdentity: String? = nil) throws -> OnchainSendAttempt? {
        guard nativeDispatchInProgress == nil, let attempt = try currentAttempt(),
              attempt.requestId == requestId, attempt.status == .accepted,
              attempt.recoveryContext?.paymentIdentity == nil ||
              PubkyPublicKeyFormat.matches(attempt.recoveryContext?.paymentIdentity, paymentIdentity)
        else { return nil }
        return attempt
    }

    func acceptedTransactionId(for requestId: PaykitPaymentRequest.ID, paymentIdentity: String? = nil) throws -> String? {
        try acceptedRequestContext(requestId: requestId, paymentIdentity: paymentIdentity)?.txid
    }

    func hasAttempt(for requestId: PaykitPaymentRequest.ID) throws -> Bool {
        try currentAttempt()?.requestId == requestId
    }

    private func currentAttemptForPending() throws -> OnchainSendAttempt? {
        do { return try currentAttempt() }
        catch {
            guard let knownAttempt else { throw error }
            return knownAttempt
        }
    }

    func pendingContext(requestId: PaykitPaymentRequest.ID? = nil, txid: String? = nil) throws -> OnchainSendPendingContext? {
        guard let attempt = try currentAttemptForPending(), attempt.requestId == requestId,
              txid == nil ? attempt.blocksNewSend : attempt.containsCandidate(txid)
        else { return nil }
        return .init(attemptId: attempt.id, walletId: attempt.walletId, txid: txid ?? attempt.txid)
    }

    func pendingAttempt(context: OnchainSendPendingContext) throws -> OnchainSendAttempt? {
        try currentAttempt().flatMap {
            $0.id == context.attemptId && $0.walletId == context.walletId && $0.containsCandidate(context.txid) ? $0 : nil
        }
    }

    func ordinaryPendingContext(txid: String? = nil) throws -> OnchainSendPendingContext? {
        guard let attempt = try currentAttemptForPending(), attempt.requestId == nil, attempt.orderId == nil else { return nil }
        if let txid {
            guard attempt.containsCandidate(txid) else { return nil }
        } else {
            // A new unsent operation cannot acquire a previous completed result.
            guard attempt.blocksNewSend else { return nil }
        }
        return OnchainSendPendingContext(attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid)
    }

    func ordinaryPendingAttempt(context: OnchainSendPendingContext) throws -> OnchainSendAttempt? {
        try currentAttempt().flatMap {
            $0.id == context.attemptId && $0.walletId == context.walletId && $0.containsCandidate(context.txid) &&
                $0.requestId == nil && $0.orderId == nil ? $0 : nil
        }
    }

    func blockingAttempt() throws -> OnchainSendAttempt? {
        try currentAttemptForPending().flatMap { $0.blocksNewSend ? $0 : nil }
    }

    func unresolvedAttempt(walletId: String) throws -> OnchainSendAttempt? {
        try currentAttempt().flatMap { $0.walletId == walletId && $0.blocksNewSend ? $0 : nil }
    }

    @discardableResult
    func observeTransaction(txid: String, walletId: String, isConfirmed: Bool = false) async throws -> Bool {
        guard let attempt = try currentAttempt(), attempt.walletId == walletId else { return false }
        // Received events can be queued for an original that a retained retry replaces.
        // With multiple unresolved candidates, only confirmation establishes the winner.
        if !isConfirmed, attempt.status != .accepted,
           (attempt.recoveryContext?.candidateTxids.count ?? 0) > 1
        {
            return false
        }
        return try await observeConfirmedTransaction(txid: txid)
    }

    /// Waits for a cancellation being broadcast, whose outcome is saved before an observed winner is.
    @discardableResult
    func observeConfirmedTransaction(txid: String) async throws -> Bool {
        await waitForCancellationBroadcast()
        guard var attempt = try currentAttempt(),
              attempt.containsCandidate(txid),
              attempt.blocksNewSend
        else { return false }
        if attempt.status == .accepted {
            return attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame
        }
        attempt.status = .accepted
        attempt.txid = attempt.storedCandidate(txid)
        knownAttempt = attempt
        try store.save([attempt])
        return true
    }
}

private actor RequestedSyncResult {
    private(set) var succeeded = false
    private(set) var baseline: UInt64?
    private(set) var isWaitOver = false

    func markSucceeded() {
        succeeded = true
    }

    func endWait() {
        isWaitOver = true
    }

    func setBaseline(_ value: UInt64) {
        baseline = value
    }
}
