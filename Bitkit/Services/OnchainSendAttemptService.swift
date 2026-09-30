import BitkitCore
import Combine
import Foundation
import LDKNode

protocol OnchainSending {
    var currentWalletIndex: Int { get }
    var onchainDispatchNode: AnyObject? { get }
    func send(address: String, sats: UInt64, satsPerVbyte: UInt32, utxosToSpend: [SpendableUtxo]?, isMaxAmount: Bool,
              expectedWalletIndex: Int?, expectedNode: AnyObject?) async throws
        -> OnchainSendResult
}

extension LightningService: OnchainSending {}

enum OnchainSendAttemptError: LocalizedError {
    case unresolved
    case duplicate
    case outcomeNotSaved
    case localFollowupNotSaved
    case preDispatch(Error)

    var errorDescription: String? {
        switch self {
        case .unresolved:
            "An earlier on-chain send is unresolved. Check its transaction before trying another send."
        case .duplicate:
            "This request or order already has an on-chain payment. Do not pay it again."
        case .outcomeNotSaved:
            "The on-chain send result could not be saved. The payment may have been sent; do not retry it."
        case .localFollowupNotSaved:
            "This payment was sent, but its local details could not be restored. Do not send it again."
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
    let amountSats: UInt64
    let isMaxAmount: Bool
    var status: Status
    var txid: String? = nil
    var rejectionReason: String? = nil
    var localFollowupComplete = false
    var followupContext: OnchainSendFollowupContext? = nil
    var transferContext: OnchainSendTransferContext? = nil

    var blocksNewSend: Bool {
        status.blocksNewSend || !localFollowupComplete
    }
}

struct OnchainSendFollowupContext: Codable, Equatable {
    let feeSats: UInt64
    let feeRate: UInt32
    let tags: [String]
    let contact: String?
    let createdAt: UInt64
}

struct OnchainSendTransferContext: Codable, Equatable {
    let clientBalanceSats: UInt64
    let txTotalSats: UInt64
    let preTransferOnchainSats: UInt64
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
                fee: context.feeSats, feeRate: context.feeRate, contact: context.contact
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
    func load() throws -> [OnchainSendAttempt] {
        guard let data = try Keychain.load(key: .onchainSendAttempts) else { return [] }
        return try JSONDecoder().decode([OnchainSendAttempt].self, from: data)
    }

    func save(_ attempts: [OnchainSendAttempt]) throws {
        try Keychain.upsert(key: .onchainSendAttempts, data: JSONEncoder().encode(attempts))
    }
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
    private let store: any OnchainSendAttemptStoring
    private let hasPaidOrder: (String) throws -> Bool
    private var knownAttempt: OnchainSendAttempt?

    init(
        store: any OnchainSendAttemptStoring = OnchainSendAttemptStore(),
        localFollowup: any OnchainSendLocalFollowupHandling = OnchainSendLocalFollowup(),
        hasPaidOrder: @escaping (String) throws -> Bool = { orderId in
            try TransferStorage.shared.getAll().contains(where: { $0.lspOrderId == orderId })
        }
    ) {
        self.localFollowup = localFollowup
        self.store = store
        self.hasPaidOrder = hasPaidOrder
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
        followupContext: OnchainSendFollowupContext? = nil,
        transferContext: OnchainSendTransferContext? = nil,
        beforeBroadcastAttempt: () async throws -> Void = {}
    ) async throws -> OnchainSendResult {
        let walletIndex = lightningService.currentWalletIndex
        let dispatchNode = lightningService.onchainDispatchNode
        if let prior = try currentAttempt(), prior.status == .accepted, let txid = prior.txid,
           prior.walletId == Self.walletId(index: walletIndex),
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
        do {
            try await beforeBroadcastAttempt()
        } catch {
            throw OnchainSendAttemptError.unresolved
        }

        let result: OnchainSendResult
        do {
            guard lightningService.currentWalletIndex == walletIndex, lightningService.onchainDispatchNode === dispatchNode else {
                throw NodeError.NotRunning(message: "Wallet or node changed before on-chain dispatch")
            }
            result = try await lightningService.send(
                address: address,
                sats: amountSats,
                satsPerVbyte: satsPerVbyte,
                utxosToSpend: utxosToSpend,
                isMaxAmount: isMaxAmount,
                expectedWalletIndex: walletIndex,
                expectedNode: dispatchNode
            )
        } catch let error as NodeError {
            do {
                try clearBeforeDispatch(attemptId: attemptId)
            } catch {
                throw OnchainSendAttemptError.unresolved
            }
            throw OnchainSendAttemptError.preDispatch(error)
        } catch {
            throw OnchainSendAttemptError.unresolved
        }

        do {
            try record(result, attemptId: attemptId)
        } catch {
            Logger.warn("Could not persist the known on-chain outcome; the durable attempt still blocks another send", context: "OnchainSendAttempt")
        }
        return result
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
        guard var attempt = try knownAttempt ?? currentAttempt(), attempt.id == attemptId, attempt.status == .pending else {
            throw OnchainSendAttemptError.outcomeNotSaved
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
        guard var attempt = try currentAttempt(), attempt.status == .accepted,
              attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame
        else { return }
        attempt.localFollowupComplete = true
        try store.save([attempt])
        knownAttempt = attempt
    }

    func resumeAcceptedOrdinarySend(walletId: String, observedTxid: String? = nil) async throws -> OnchainSendLocalResolution? {
        guard var attempt = try currentAttempt(), attempt.walletId == walletId,
              attempt.requestId == nil, attempt.orderId == nil, let txid = attempt.txid
        else { return nil }
        if let observedTxid {
            guard txid.caseInsensitiveCompare(observedTxid) == .orderedSame else { return nil }
            if attempt.status != .accepted {
                attempt.status = .accepted
                knownAttempt = attempt
                try store.save([attempt])
            }
        }
        guard attempt.status == .accepted else { return nil }
        let activity = try await localFollowup.save(attempt)
        try acknowledgeLocalFollowup(txid: txid)
        let resolution = OnchainSendLocalResolution(
            attemptId: attempt.id, walletId: walletId, txid: txid, amountSats: activity.value, contact: activity.contact, activity: activity
        )
        Self.localResolutionSubject.send(resolution)
        return resolution
    }

    func acceptedRequestAttempt() throws -> OnchainSendAttempt? {
        try currentAttempt().flatMap { $0.requestId != nil && $0.status == .accepted && !$0.localFollowupComplete ? $0 : nil }
    }

    @discardableResult
    func resumeAcceptedRequestSend(requestId: PaykitPaymentRequest.ID, txid: String) async throws -> Bool {
        guard let attempt = try currentAttempt(), attempt.requestId == requestId, attempt.orderId == nil,
              attempt.status == .accepted, attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame
        else { return false }
        if !attempt.localFollowupComplete {
            _ = try await localFollowup.save(attempt)
            try acknowledgeLocalFollowup(txid: txid)
        }
        return true
    }

    @discardableResult
    func resumeAcceptedTransfer(walletId: String, using transferService: TransferService) async throws -> Bool {
        guard let attempt = try currentAttempt(), attempt.walletId == walletId,
              attempt.status == .accepted, attempt.requestId == nil, attempt.orderId != nil, attempt.txid != nil
        else { return false }
        return try await restoreAcceptedTransfer(attempt, using: transferService)
    }

    @discardableResult
    func resumeAcceptedTransfer(orderId: String, txid: String, using transferService: TransferService) async throws -> Bool {
        guard let attempt = try currentAttempt(), attempt.orderId == orderId,
              attempt.status == .accepted, attempt.requestId == nil,
              attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame
        else { return false }
        return try await restoreAcceptedTransfer(attempt, using: transferService)
    }

    private func restoreAcceptedTransfer(_ attempt: OnchainSendAttempt, using transferService: TransferService) async throws -> Bool {
        guard let savedOrderId = attempt.orderId, let txid = attempt.txid else { return false }
        guard !attempt.localFollowupComplete else { return true }
        guard let context = attempt.followupContext, let transfer = attempt.transferContext else {
            throw OnchainSendAttemptError.localFollowupNotSaved
        }
        try await CoreService.shared.activity.upsertPreActivityMetadata([BitkitCore.PreActivityMetadata(
            walletId: WalletScope.default, paymentId: txid, tags: context.tags, paymentHash: nil,
            txId: txid, address: attempt.address, isReceive: false, feeRate: UInt64(context.feeRate),
            isTransfer: true, channelId: nil, createdAt: context.createdAt
        )])
        _ = try await transferService.createTransfer(
            type: .toSpending, amountSats: transfer.clientBalanceSats, fundingTxId: txid,
            lspOrderId: savedOrderId, txTotalSats: transfer.txTotalSats, preTransferOnchainSats: transfer.preTransferOnchainSats
        )
        try acknowledgeLocalFollowup(txid: txid)
        return true
    }

    func clearBeforeDispatch(attemptId: UUID) throws {
        var attempts = try store.load()
        guard let index = attempts.firstIndex(where: { $0.id == attemptId && $0.status == .pending }) else { return }
        guard knownAttempt?.id != attemptId || knownAttempt?.status == .pending else { return }
        attempts.remove(at: index)
        try store.save(attempts)
        knownAttempt = nil
    }

    func acceptedTransactionId(for requestId: PaykitPaymentRequest.ID) throws -> String? {
        if let knownAttempt, knownAttempt.requestId == requestId, knownAttempt.status == .accepted {
            return knownAttempt.txid
        }
        return try currentAttempt().flatMap { $0.requestId == requestId && $0.status == .accepted ? $0.txid : nil }
    }

    func hasAttempt(for requestId: PaykitPaymentRequest.ID) throws -> Bool {
        try currentAttempt()?.requestId == requestId
    }

    func unresolvedAttempt(walletId: String) throws -> OnchainSendAttempt? {
        try currentAttempt().flatMap { $0.walletId == walletId && $0.blocksNewSend ? $0 : nil }
    }

    @discardableResult
    func observeConfirmedTransaction(txid: String) throws -> Bool {
        guard var attempt = try currentAttempt(),
              attempt.txid?.caseInsensitiveCompare(txid) == .orderedSame,
              attempt.blocksNewSend
        else { return false }
        attempt.status = .accepted
        knownAttempt = attempt
        try store.save([attempt])
        return true
    }
}
