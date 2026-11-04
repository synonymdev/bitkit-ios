import Foundation

/// A signed hardware-wallet send handed to the network whose outcome is not known.
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
}

protocol HwHeldBroadcastResolving {
    /// Whether the wallet has seen the transaction. A failed read proves nothing.
    func isObserved(_ held: HwHeldBroadcast) async -> Bool
}

struct HwHeldBroadcastResolver: HwHeldBroadcastResolving {
    func isObserved(_ held: HwHeldBroadcast) async -> Bool {
        guard let txid = try? SignedTransactionId.fromHex(held.serializedTx) else { return false }
        return await (try? CoreService.shared.activity.getOnchainActivityByTxId(txid: txid, walletId: held.walletId)) != nil
    }
}

/// Keeps every hardware send whose broadcast may have gone out, across sheets and launches, so the payment it makes is never
/// signed again. Each is written before its broadcast and kept until the broadcast succeeds or proves nothing was sent, or the
/// wallet sees the transaction.
final class HwHeldBroadcastStore: @unchecked Sendable {
    static let shared = HwHeldBroadcastStore()

    private let defaults: UserDefaults
    private let resolver: any HwHeldBroadcastResolving
    private let key = "hwHeldBroadcasts"
    /// Keeps each read-modify-write whole.
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, resolver: any HwHeldBroadcastResolving = HwHeldBroadcastResolver()) {
        self.defaults = defaults
        self.resolver = resolver
    }

    func hold(_ held: HwHeldBroadcast) throws {
        try lock.withLock {
            var entries = try load().filter { $0.serializedTx != held.serializedTx }
            entries.append(held)
            try save(entries)
        }
    }

    func release(_ signedTx: HwFundingSignedTx) throws {
        try lock.withLock {
            let entries = try load()
            let remaining = entries.filter { $0.serializedTx != signedTx.serializedTx }
            guard remaining.count != entries.count else { return }
            try save(remaining)
        }
    }

    /// The held send of this payment that may still confirm. A store that cannot be read throws, so the payment is not signed
    /// again.
    func unresolvedSend(walletId: String, address: String, amountSats: UInt64) async throws -> HwHeldBroadcast? {
        let entries = try lock.withLock { try load() }
        for held in entries where held.walletId == walletId && held.address == address && held.amountSats == amountSats {
            guard await resolver.isObserved(held) else { return held }
            Logger.info("Released a held hardware send the wallet has seen", context: "HwHeldBroadcastStore")
            try release(held.signedTx)
        }
        return nil
    }

    private func load() throws -> [HwHeldBroadcast] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([HwHeldBroadcast].self, from: data)
    }

    private func save(_ entries: [HwHeldBroadcast]) throws {
        if entries.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            try defaults.set(JSONEncoder().encode(entries), forKey: key)
        }
    }
}
