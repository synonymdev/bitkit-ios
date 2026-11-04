import Foundation

/// A signed hardware-wallet send handed to the network whose outcome is not known. Fields added later must be optional, so an
/// older entry still decodes.
struct HwHeldBroadcast: Codable, Equatable {
    let walletId: String
    let address: String
    let amountSats: UInt64
    let serializedTx: String
    let miningFeeSats: UInt64
    let feeRate: Float
    let totalSpent: UInt64

    init(_ signedTx: HwFundingSignedTx, walletId: String, address: String, amountSats: UInt64) {
        self.walletId = walletId
        self.address = address
        self.amountSats = amountSats
        serializedTx = signedTx.serializedTx
        miningFeeSats = signedTx.miningFeeSats
        feeRate = signedTx.feeRate
        totalSpent = signedTx.totalSpent
    }

    var signedTx: HwFundingSignedTx {
        HwFundingSignedTx(serializedTx: serializedTx, miningFeeSats: miningFeeSats, feeRate: feeRate, totalSpent: totalSpent)
    }

    func pays(walletId: String, address: String, amountSats: UInt64) -> Bool {
        self.walletId == walletId && self.amountSats == amountSats && self.address.caseInsensitiveCompare(address) == .orderedSame
    }
}

enum HwHeldBroadcastStoreError: Error, Equatable {
    /// An earlier hardware send of this wallet cannot be read, so no new one is signed.
    case unreadable
}

/// A held send found for a payment, and whether the wallet has seen it.
enum HwHeldSend: Equatable {
    /// It may have gone out, so it is only ever broadcast again as signed.
    case unresolved(HwHeldBroadcast)
    /// The wallet has seen it; it is recorded and released once its pending screen completes it.
    case observed(HwHeldBroadcast)

    var held: HwHeldBroadcast {
        switch self {
        case let .unresolved(held), let .observed(held):
            held
        }
    }
}

/// One hand-off of a held send's bytes to the network. Counted, so that a "not sent" answer of one never releases bytes
/// another may have sent.
struct HwHeldDispatch: Equatable {
    let serializedTx: String
    let generation: Int
}

/// What a rebroadcast of a held send's own signed bytes proved.
enum HwHeldRebroadcastOutcome: Equatable {
    /// The node took it, or the wallet has seen it; it stays held until the wallet sees it.
    case accepted
    /// It can never confirm, so it was released and the payment can be made again.
    case neverConfirms
    /// It may still confirm, so it stays held.
    case mayConfirm
}

protocol HwHeldBroadcastResolving {
    /// Whether the wallet has seen the transaction. Throws when that cannot be read.
    func isObserved(_ held: HwHeldBroadcast) async throws -> Bool
    /// Whether a fresh read of the account shows one of its coins spent by another transaction deep enough to be final.
    func isSpentElsewhere(_ held: HwHeldBroadcast) async throws -> Bool
}

struct HwHeldBroadcastResolver: HwHeldBroadcastResolving {
    /// LDK's ANTI_REORG_DELAY, the depth at which the node wallet treats its own spends as final.
    static let finalConfirmations: UInt32 = 6
    /// The most transactions one check reads, so it finishes while the pending screen waits.
    static let maximumSpendReads = 25

    func isObserved(_ held: HwHeldBroadcast) async throws -> Bool {
        let txid = try SignedTransactionId.fromHex(held.serializedTx)
        return try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid, walletId: held.walletId) != nil
    }

    func isSpentElsewhere(_ held: HwHeldBroadcast) async throws -> Bool {
        let txid = try SignedTransactionId.fromHex(held.serializedTx).lowercased()
        let coins = try Set(SignedTransactionId.inputsFromHex(held.serializedTx).map {
            OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout)
        })
        let parents = Set(coins.map(\.txid))
        let account = try HwWalletManager.persistedFundingAccount(walletId: held.walletId)
        let electrumUrl = OnChainHwService.getElectrumUrl()
        let network = OnChainHwService.appDefaultCoinType
        let history = try await OnChainHwService.shared.getTransactionHistory(
            extendedKey: account.xpub, electrumUrl: electrumUrl, network: network, scriptType: account.accountType
        )
        // A coin is spent no earlier than the block that created it
        guard let fundedAt = history.transactions.filter({ parents.contains($0.txid.lowercased()) }).compactMap(\.blockHeight).min()
        else { return false }
        let spends = history.transactions.filter {
            $0.sent > 0 && $0.confirmations >= Self.finalConfirmations && ($0.blockHeight ?? 0) >= fundedAt && $0.txid.lowercased() != txid
        }
        guard spends.count <= Self.maximumSpendReads else { throw HwHeldSpendCheckError.tooManySpends }
        for spend in spends {
            let detail = try await OnChainHwService.shared.getTransactionDetail(
                extendedKey: account.xpub, electrumUrl: electrumUrl, txid: spend.txid, network: network, scriptType: account.accountType
            )
            if detail.inputs.contains(where: { coins.contains(OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout)) }) {
                return true
            }
        }
        return false
    }
}

enum HwHeldSpendCheckError: Error {
    /// More final spends than one check reads, so it proves nothing.
    case tooManySpends
}

/// Keeps every hardware send whose broadcast may have gone out, across sheets and launches, so the payment it makes is never
/// signed again. Each is written before every broadcast of its bytes and kept until the payment is recorded after a successful
/// broadcast or once the wallet has seen it, a broadcast proves nothing was sent while no other broadcast of the same bytes
/// can have been taken, or a rebroadcast proves it can never confirm.
///
/// Entries are read one by one: one that cannot be read is kept as written and refuses new sends of its wallet, or of every
/// wallet when its wallet cannot be read either.
final class HwHeldBroadcastStore: @unchecked Sendable {
    static let shared = HwHeldBroadcastStore()

    private struct Entry {
        let raw: Any
        let held: HwHeldBroadcast?
        let walletId: String?
    }

    private struct DispatchState {
        var generation = 0
        var inFlight = 0
        var isAccepted = false
    }

    private let defaults: UserDefaults
    private let resolver: any HwHeldBroadcastResolving
    private let key = "hwHeldBroadcasts"
    private let lock = NSLock()
    private var dispatches: [String: DispatchState] = [:]

    init(defaults: UserDefaults = .standard, resolver: any HwHeldBroadcastResolving = HwHeldBroadcastResolver()) {
        self.defaults = defaults
        self.resolver = resolver
    }

    func hold(_ held: HwHeldBroadcast) throws {
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(held))
        try lock.withLock { try holdLocked(held, raw: raw) }
    }

    func release(_ signedTx: HwFundingSignedTx) throws {
        try lock.withLock { try releaseLocked(signedTx.serializedTx) }
    }

    func isHeld(_ signedTx: HwFundingSignedTx) throws -> Bool {
        try lock.withLock { try load().contains { $0.held?.serializedTx == signedTx.serializedTx } }
    }

    /// Persists the send and counts a dispatch of its bytes, before they are handed to the network. A rebroadcast starts only
    /// while the send is still held and no other dispatch of the same bytes is in flight, and returns nil otherwise.
    func beginDispatch(_ held: HwHeldBroadcast, isRebroadcast: Bool) throws -> HwHeldDispatch? {
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(held))
        return try lock.withLock {
            var state = dispatches[held.serializedTx] ?? DispatchState()
            if isRebroadcast {
                guard state.inFlight == 0, try load().contains(where: { $0.held?.serializedTx == held.serializedTx }) else { return nil }
            }
            try holdLocked(held, raw: raw)
            state.generation += 1
            state.inFlight += 1
            dispatches[held.serializedTx] = state
            return HwHeldDispatch(serializedTx: held.serializedTx, generation: state.generation)
        }
    }

    func endDispatch(_ dispatch: HwHeldDispatch, isAccepted: Bool) {
        lock.withLock {
            guard var state = dispatches[dispatch.serializedTx] else { return }
            state.inFlight = max(0, state.inFlight - 1)
            state.isAccepted = state.isAccepted || isAccepted
            dispatches[dispatch.serializedTx] = state
        }
    }

    func isDispatching(_ signedTx: HwFundingSignedTx) -> Bool {
        lock.withLock { (dispatches[signedTx.serializedTx]?.inFlight ?? 0) > 0 }
    }

    /// Releases the send after `dispatch` proved nothing was sent, unless another dispatch of the same bytes began since, is in
    /// flight or was taken, as the network may then have it. Returns whether it was released.
    func releaseUnsent(_ dispatch: HwHeldDispatch) throws -> Bool {
        try lock.withLock {
            let state = dispatches[dispatch.serializedTx] ?? DispatchState()
            guard state.generation == dispatch.generation, state.inFlight == 0, !state.isAccepted else { return false }
            try releaseLocked(dispatch.serializedTx)
            return true
        }
    }

    /// The held send of this payment, and whether the wallet has seen it. A held send of this wallet that cannot be read
    /// throws, so the payment is not signed again.
    func heldSend(walletId: String, address: String, amountSats: UInt64) async throws -> HwHeldSend? {
        let entries = try lock.withLock { try load() }
        guard !entries.contains(where: { $0.held == nil && ($0.walletId == nil || $0.walletId == walletId) }) else {
            throw HwHeldBroadcastStoreError.unreadable
        }
        guard let held = entries.compactMap(\.held).first(where: { $0.pays(walletId: walletId, address: address, amountSats: amountSats) })
        else { return nil }
        return await isObserved(held) ? .observed(held) : .unresolved(held)
    }

    /// Whether the wallet has seen the held send. A failed read counts as not seen.
    func isObserved(_ held: HwHeldBroadcast) async -> Bool {
        await (try? resolver.isObserved(held)) == true
    }

    /// Broadcasts the held send's own signed bytes again, which can never pay twice, and releases it only when the refusal
    /// proves it can never confirm and the wallet has not seen it. A refused coin counts only once a fresh read shows it
    /// spent by another final transaction, as a confirmed send is refused the same way.
    func rebroadcast(_ held: HwHeldBroadcast, broadcast: () async throws -> Void) async -> HwHeldRebroadcastOutcome {
        do {
            if try await resolver.isObserved(held) {
                return .accepted
            }
        } catch {
            return .mayConfirm
        }
        let dispatch: HwHeldDispatch
        do {
            guard let started = try beginDispatch(held, isRebroadcast: true) else {
                return (try? isHeld(held.signedTx)) == false ? .neverConfirms : .mayConfirm
            }
            dispatch = started
        } catch {
            return .mayConfirm
        }
        do {
            try await broadcast()
            endDispatch(dispatch, isAccepted: true)
            return .accepted
        } catch {
            endDispatch(dispatch, isAccepted: false)
            let isInvalid = error.isHardwareBroadcastNeverConfirmable()
            let isInputMissing = !isInvalid && error.isHardwareBroadcastInputsMissing()
            guard isInvalid || isInputMissing else {
                Logger.warn("A rebroadcast of a held hardware send was not taken: \(error)", context: "HwHeldBroadcastStore")
                return .mayConfirm
            }
            do {
                if isInputMissing, try await !resolver.isSpentElsewhere(held) {
                    return .mayConfirm
                }
                if try await resolver.isObserved(held) {
                    return .accepted
                }
                try release(held.signedTx)
            } catch {
                return .mayConfirm
            }
            Logger.info("Released a held hardware send that can never confirm: \(error)", context: "HwHeldBroadcastStore")
            return .neverConfirms
        }
    }

    private func holdLocked(_ held: HwHeldBroadcast, raw: Any) throws {
        var entries = try load().filter { $0.held?.serializedTx != held.serializedTx }
        entries.append(Entry(raw: raw, held: held, walletId: held.walletId))
        try save(entries)
    }

    private func releaseLocked(_ serializedTx: String) throws {
        let entries = try load()
        let remaining = entries.filter { $0.held?.serializedTx != serializedTx }
        guard remaining.count != entries.count else { return }
        try save(remaining)
    }

    private func load() throws -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let raws = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw HwHeldBroadcastStoreError.unreadable
        }
        return raws.map { raw in
            guard let object = raw as? [String: Any] else { return Entry(raw: raw, held: nil, walletId: nil) }
            let held = (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(HwHeldBroadcast.self, from: $0) }
            return Entry(raw: raw, held: held, walletId: object["walletId"] as? String)
        }
    }

    private func save(_ entries: [Entry]) throws {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            try defaults.set(JSONSerialization.data(withJSONObject: entries.map(\.raw), options: .fragmentsAllowed), forKey: key)
        }
    }
}
