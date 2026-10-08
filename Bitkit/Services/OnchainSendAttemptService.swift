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
}

extension LightningService: OnchainSending {
    func prepareOnchainSend(
        address: String, sats: UInt64, satsPerVbyte: UInt32,
        utxosToSpend: [SpendableUtxo]?, isMaxAmount: Bool,
        expectedWalletIndex: Int, expectedNode: AnyObject?, paymentDeadline: PaykitPreciseInstant?
    ) async throws -> PreparedOnchainSendDispatch {
        guard let node = onchainDispatchNode as? Node else { throw NodeError.NotRunning(message: "Node not set up") }
        let (prepared, txid, inputs, recipientAmountSats) = try await ServiceQueue.background(.ldk, wrapErrors: false) {
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
                    prepared.recipientAmountSats())
        }
        return PreparedOnchainSendDispatch(
            txid: txid, inputs: inputs, recipientAmountSats: recipientAmountSats,
            broadcast: {
                try await ServiceQueue.background(.ldk, wrapErrors: false) {
                    guard self.currentWalletIndex == expectedWalletIndex, self.onchainDispatchNode === node, expectedNode === node else {
                        throw NodeError.NotRunning(message: "Wallet or node changed before on-chain dispatch")
                    }
                    try PaykitPaymentRequest.checkPaymentDeadline(paymentDeadline)
                    return try prepared.broadcast()
                }
            }
        )
    }
}

struct OnchainSendInput: Codable, Equatable, Hashable {
    let txid: String
    let vout: UInt32

    var utxo: SpendableUtxo {
        SpendableUtxo(outpoint: OutPoint(txid: Txid(txid), vout: vout), valueSats: 0)
    }
}

struct PreparedOnchainSendDispatch {
    let txid: String
    let inputs: [OnchainSendInput]
    let recipientAmountSats: UInt64
    let broadcast: () async throws -> OnchainSendResult
}

struct OnchainSendRecoveryContext: Codable, Equatable {
    let inputs: [OnchainSendInput]
    let satsPerVbyte: UInt32
    let paymentIdentity: String?
    var candidateTxids: [String]
    var candidateFeeRates: [String: UInt32]? = nil

    func feeRate(for txid: String) -> UInt32? {
        if let rate = candidateFeeRates?[txid.lowercased()] {
            return rate > 0 ? rate : nil
        }
        return candidateTxids.first?.caseInsensitiveCompare(txid) == .orderedSame ? satsPerVbyte : nil
    }
}

enum OnchainSendAttemptError: LocalizedError {
    case unresolved
    case duplicate
    case outcomeNotSaved
    case localFollowupNotSaved
    case retryConstruction
    case retryUnavailable
    case preDispatch(Error)

    var errorDescription: String? {
        switch self {
        case .unresolved:
            t("wallet__onchain_send_unresolved")
        case .duplicate:
            t("wallet__onchain_send_duplicate")
        case .outcomeNotSaved:
            t("wallet__onchain_outcome_save_failed")
        case .localFollowupNotSaved:
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

    var canRetrySamePayment: Bool {
        guard status == .pending || status == .unknown || status == .rejected, let recovery = recoveryContext,
              !recovery.inputs.isEmpty, let txid, recovery.candidateTxids.contains(txid)
        else { return false }
        return requestId == nil || recovery.paymentIdentity != nil
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
                feeIsExact: attempt.recoveryContext.map { $0.candidateTxids.first?.caseInsensitiveCompare(txid) != .orderedSame } ?? false
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

struct OnchainSendPendingContext: Hashable {
    let attemptId: UUID
    let walletId: String
    let txid: String?
}

actor OnchainSendAttemptService {
    static let shared = OnchainSendAttemptService()

    static func walletId(index: Int) -> String {
        "node:\(Env.networkName):\(WalletScope.default):\(index)"
    }

    private static let localResolutionSubject = PassthroughSubject<OnchainSendLocalResolution, Never>()

    nonisolated static var localResolutionPublisher: AnyPublisher<OnchainSendLocalResolution, Never> {
        localResolutionSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    private let localFollowup: any OnchainSendLocalFollowupHandling
    private let winningFee: (OnchainSendAttempt) async throws -> UInt64?
    private let store: any OnchainSendAttemptStoring
    private let hasPaidOrder: (String) throws -> Bool
    private var knownAttempt: OnchainSendAttempt?
    private var nativeDispatchInProgress: UUID?
    private var requestFollowupInProgress: UUID?

    init(
        store: any OnchainSendAttemptStoring = OnchainSendAttemptStore(),
        localFollowup: any OnchainSendLocalFollowupHandling = OnchainSendLocalFollowup(),
        winningFee: @escaping (OnchainSendAttempt) async throws -> UInt64? = OnchainSendLocalFollowup.observedFee,
        hasPaidOrder: @escaping (String) throws -> Bool = { orderId in
            try TransferStorage.shared.getAll().contains(where: { $0.lspOrderId == orderId })
        }
    ) {
        self.localFollowup = localFollowup
        self.winningFee = winningFee
        self.store = store
        self.hasPaidOrder = hasPaidOrder
    }

    func backupSnapshot(wallet: PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet,
                        proofs: [PendingPaykitPaymentProof]) throws -> PaykitPaymentStateBackup.ActiveOnchainAttempt?
    {
        guard let attempt = try currentAttempt(), attempt.blocksNewSend else { return nil }
        if attempt.status == .pending, attempt.txid == nil,
           attempt.recoveryContext?.inputs.isEmpty != false,
           attempt.recoveryContext?.candidateTxids.isEmpty != false
        {
            throw OnchainSendAttemptError.unresolved
        }
        let wire = try PaykitPaymentStateBackup.ActiveOnchainAttempt(attempt, wallet: wallet)
        _ = try wire.restored(wallet: wallet, proofs: proofs)
        return wire
    }

    func restoreBackup(_ attempt: OnchainSendAttempt?) throws {
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.unresolved }
        if let previous = try currentAttempt(), previous.blocksNewSend {
            // A restore must not erase a newer unresolved candidate or another original operation.
            guard let attempt, previous == attempt else { throw OnchainSendAttemptError.unresolved }
            return
        }
        try store.save(attempt.map { [$0] } ?? [])
        knownAttempt = attempt
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
        beforeBroadcastAttempt: () async throws -> Void = {}
    ) async throws -> OnchainSendResult {
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.unresolved }
        let walletIndex = lightningService.currentWalletIndex
        let dispatchNode = lightningService.onchainDispatchNode
        if let prior = try currentAttempt(), prior.status == .accepted, let txid = prior.txid,
           prior.walletId == Self.walletId(index: walletIndex),
           prior.recoveryContext?.paymentIdentity == nil || prior.recoveryContext?.paymentIdentity == paymentIdentity,
           (requestId != nil && prior.requestId == requestId) || (orderId != nil && prior.orderId == orderId)
        {
            return .accepted(txid: txid)
        }
        if let orderId, try hasPaidOrder(orderId) {
            throw OnchainSendAttemptError.duplicate
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
                attempt.amountSats = prepared.recipientAmountSats
                attempt.txid = prepared.txid
                attempt.recoveryContext = OnchainSendRecoveryContext(
                    inputs: prepared.inputs, satsPerVbyte: satsPerVbyte, paymentIdentity: paymentIdentity,
                    candidateTxids: [prepared.txid], candidateFeeRates: [prepared.txid.lowercased(): satsPerVbyte]
                )
                try store.save([attempt])
                knownAttempt = attempt
            }
            try await beforeBroadcastAttempt()
            try checkWallet(lightningService, index: walletIndex, node: dispatchNode)
        } catch {
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
        catch { result = .unknown(txid: prepared.txid) }

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
        authorize: (OnchainSendAttempt, UInt32) async throws -> Void
    ) async throws -> OnchainSendResult {
        guard nativeDispatchInProgress == nil, let original = try currentAttempt(),
              original.id == context.attemptId, original.walletId == context.walletId,
              original.containsCandidate(context.txid), original.canRetrySamePayment,
              let recovery = original.recoveryContext
        else { throw OnchainSendAttemptError.unresolved }
        let index = sender.currentWalletIndex
        let node = sender.onchainDispatchNode
        guard original.walletId == Self.walletId(index: index) else { throw OnchainSendAttemptError.unresolved }
        nativeDispatchInProgress = original.id
        defer { nativeDispatchInProgress = nil }
        let authorizedFeeRate = satsPerVbyte ?? recovery.satsPerVbyte
        guard authorizedFeeRate > 0 else { throw OnchainSendAttemptError.unresolved }
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
              attempt.recoveryContext == recovery
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
        // Keep the original rejected/unknown state until a real new outcome arrives.
        // A crash here still recognizes both possible payments and cannot unlock the wallet.
        try store.save([attempt])
        knownAttempt = attempt
        // One authorization, after preparation and immediately before native dispatch.
        // It validates the original payer/request/order and the chosen fee policy without
        // repeating initial proof-start/consume side effects.
        do {
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
        catch { result = .unknown(txid: prepared.txid) }
        do { try record(result, attemptId: original.id) }
        catch { Logger.warn("Could not persist the known recovery outcome; original inputs remain guarded", context: "OnchainSendAttempt") }
        return (try? winningResult(attemptId: original.id)) ?? result
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
        guard nativeDispatchInProgress == nil else { throw OnchainSendAttemptError.unresolved }
        if let previous = try currentAttempt() {
            guard !previous.blocksNewSend else {
                throw OnchainSendAttemptError.unresolved
            }
            guard !(requestId != nil && previous.requestId == requestId),
                  !(orderId != nil && previous.orderId == orderId)
            else { throw OnchainSendAttemptError.duplicate }
        }
        if let orderId, try hasPaidOrder(orderId) {
            throw OnchainSendAttemptError.duplicate
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

    private func currentAttempt() throws -> OnchainSendAttempt? {
        let attempts = try store.load()
        guard attempts.count <= 1 else { throw OnchainSendAttemptError.unresolved }
        guard let saved = attempts.first else { return nil }
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
        guard var attempt = try currentAttempt(), attempt.walletId == walletId,
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
        guard attempt.status == .accepted, nativeDispatchInProgress == nil else { return nil }
        guard let txid = attempt.txid else { return nil }
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
        let observed = isOriginal ? context.feeSats : try await winningFee(original)
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
        if attempt.localFollowupComplete { return !onlyIfIncomplete }
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
    func resumeAcceptedTransfer(walletId: String, using transferService: TransferService) async throws -> Bool {
        guard nativeDispatchInProgress == nil, let attempt = try currentAttempt(), attempt.walletId == walletId,
              attempt.status == .accepted, attempt.requestId == nil, attempt.orderId != nil, attempt.txid != nil
        else { return false }
        return try await restoreAcceptedTransfer(attempt, using: transferService)
    }

    @discardableResult
    func resumeAcceptedTransfer(orderId: String, txid: String, using transferService: TransferService) async throws -> Bool {
        guard nativeDispatchInProgress == nil, let attempt = try currentAttempt(), attempt.orderId == orderId,
              attempt.status == .accepted, attempt.requestId == nil,
              attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame
        else { return false }
        return try await restoreAcceptedTransfer(attempt, using: transferService)
    }

    private func restoreAcceptedTransfer(_ attempt: OnchainSendAttempt, using transferService: TransferService) async throws -> Bool {
        guard let savedOrderId = attempt.orderId, let txid = attempt.txid else { return false }
        guard !attempt.localFollowupComplete else { return true }
        let attempt = try await winningFollowupAttempt(attempt)
        guard let context = attempt.followupContext, let transfer = attempt.transferContext else {
            throw OnchainSendAttemptError.localFollowupNotSaved
        }
        try await CoreService.shared.activity.upsertPreActivityMetadata([BitkitCore.PreActivityMetadata(
            walletId: WalletScope.default, paymentId: txid, tags: context.tags, paymentHash: nil,
            txId: txid, address: attempt.address, isReceive: false, feeRate: UInt64(context.feeRate),
            isTransfer: true, channelId: nil, createdAt: context.createdAt
        )])
        let isSuccessor = attempt.recoveryContext.map { $0.candidateTxids.first?.caseInsensitiveCompare(txid) != .orderedSame } ?? false
        _ = try await transferService.createTransfer(
            type: .toSpending, amountSats: transfer.clientBalanceSats, fundingTxId: txid,
            lspOrderId: savedOrderId, txTotalSats: isSuccessor ? attempt.amountSats + context.feeSats : transfer.txTotalSats,
            preTransferOnchainSats: transfer.preTransferOnchainSats
        )
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

    func resolvedAcceptedTransfer(context: OnchainSendPendingContext, using transferService: TransferService) async throws
        -> OnchainSendLocalResolution?
    {
        guard let attempt = try pendingAttempt(context: context), attempt.orderId != nil, attempt.requestId == nil,
              attempt.status == .accepted, let txid = attempt.txid,
              try await restoreAcceptedTransfer(attempt, using: transferService),
              let activity = try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid),
              activity.txType == .sent, activity.isTransfer
        else { return nil }
        return OnchainSendLocalResolution(attemptId: attempt.id, walletId: attempt.walletId, txid: txid,
                                          amountSats: activity.value, contact: activity.contact, activity: activity)
    }

    func clearBeforeDispatch(attemptId: UUID) throws {
        var attempts = try store.load()
        guard let index = attempts.firstIndex(where: { $0.id == attemptId && $0.status == .pending }) else { return }
        guard knownAttempt?.id != attemptId || knownAttempt?.status == .pending else { return }
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

    func orderPendingContext(orderId: String) throws -> OnchainSendPendingContext? {
        guard let attempt = try currentAttemptForPending(), attempt.requestId == nil,
              attempt.orderId == orderId, attempt.blocksNewSend else { return nil }
        return .init(attemptId: attempt.id, walletId: attempt.walletId, txid: attempt.txid)
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

    func unresolvedAttempt(walletId: String) throws -> OnchainSendAttempt? {
        try currentAttempt().flatMap { $0.walletId == walletId && $0.blocksNewSend ? $0 : nil }
    }

    @discardableResult
    func observeTransaction(txid: String, walletId: String, isConfirmed: Bool = false) throws -> Bool {
        guard let attempt = try currentAttempt(), attempt.walletId == walletId else { return false }
        // Received events can be queued for an original that a retained retry replaces.
        // With multiple unresolved candidates, only confirmation establishes the winner.
        if !isConfirmed, attempt.status != .accepted,
           (attempt.recoveryContext?.candidateTxids.count ?? 0) > 1
        {
            return false
        }
        return try observeConfirmedTransaction(txid: txid)
    }

    @discardableResult
    func observeConfirmedTransaction(txid: String) throws -> Bool {
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
