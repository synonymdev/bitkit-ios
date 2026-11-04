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

    func isObserved(_ held: HwHeldBroadcast) async throws -> Bool {
        let txid = try SignedTransactionId.fromHex(held.serializedTx)
        return try await CoreService.shared.activity.getOnchainActivityByTxId(txid: txid, walletId: held.walletId) != nil
    }

    func isSpentElsewhere(_ held: HwHeldBroadcast) async throws -> Bool {
        let txid = try SignedTransactionId.fromHex(held.serializedTx).lowercased()
        let coins = try Set(SignedTransactionId.inputsFromHex(held.serializedTx).map {
            OnchainSendInput(txid: $0.txid.lowercased(), vout: $0.vout)
        })
        let account = try HwWalletManager.persistedFundingAccount(walletId: held.walletId)
        let electrumUrl = OnChainHwService.getElectrumUrl()
        let network = OnChainHwService.appDefaultCoinType
        let history = try await OnChainHwService.shared.getTransactionHistory(
            extendedKey: account.xpub, electrumUrl: electrumUrl, network: network, scriptType: account.accountType
        )
        for spend in history.transactions where spend.sent > 0 && spend.confirmations >= Self.finalConfirmations &&
            spend.txid.lowercased() != txid
        {
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

/// Keeps every hardware send whose broadcast may have gone out, across sheets and launches, so the payment it makes is never
/// signed again. Each is written before its broadcast and kept until the payment is recorded after a successful broadcast,
/// the broadcast proves nothing was sent, the wallet sees the transaction, or a rebroadcast proves it can never confirm.
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

    private let defaults: UserDefaults
    private let resolver: any HwHeldBroadcastResolving
    private let key = "hwHeldBroadcasts"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, resolver: any HwHeldBroadcastResolving = HwHeldBroadcastResolver()) {
        self.defaults = defaults
        self.resolver = resolver
    }

    func hold(_ held: HwHeldBroadcast) throws {
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(held))
        try lock.withLock {
            var entries = try load().filter { $0.held?.serializedTx != held.serializedTx }
            entries.append(Entry(raw: raw, held: held, walletId: held.walletId))
            try save(entries)
        }
    }

    func release(_ signedTx: HwFundingSignedTx) throws {
        try lock.withLock {
            let entries = try load()
            let remaining = entries.filter { $0.held?.serializedTx != signedTx.serializedTx }
            guard remaining.count != entries.count else { return }
            try save(remaining)
        }
    }

    /// The held send of this payment that may still confirm. A held send of this wallet that cannot be read throws, so the
    /// payment is not signed again.
    func unresolvedSend(walletId: String, address: String, amountSats: UInt64) async throws -> HwHeldBroadcast? {
        let entries = try lock.withLock { try load() }
        guard !entries.contains(where: { $0.held == nil && ($0.walletId == nil || $0.walletId == walletId) }) else {
            throw HwHeldBroadcastStoreError.unreadable
        }
        for held in entries.compactMap(\.held) where held.pays(walletId: walletId, address: address, amountSats: amountSats) {
            guard await (try? resolver.isObserved(held)) == true else { return held }
            Logger.info("Released a held hardware send the wallet has seen", context: "HwHeldBroadcastStore")
            try release(held.signedTx)
        }
        return nil
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
        do {
            try await broadcast()
            return .accepted
        } catch {
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
