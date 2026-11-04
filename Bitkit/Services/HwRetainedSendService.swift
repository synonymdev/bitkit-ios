import Foundation

/// A signed ordinary hardware-wallet send whose broadcast may have gone out. Rebroadcasting these same bytes cannot pay
/// twice, because the txid stays the same, while a new signature can create a second payment.
/// `serializedTx` reveals the payment, so never log it or this record.
struct HwRetainedSend: Codable, Equatable {
    let walletId: String
    let address: String
    let sats: UInt64
    let serializedTx: String
    let miningFeeSats: UInt64
    let feeRate: Float
    let totalSpent: UInt64
    var retryWasRefused = false
}

enum HwRetainedSendError: Error {
    case differentTransactionRetained
    /// The stored entry was read but cannot be decoded. Carries nothing from the entry, because those bytes reveal the payment.
    case corruptStore
}

protocol HwRetainedSendStoring: Sendable {
    func load(walletId: String) throws -> HwRetainedSend?
    func save(_ send: HwRetainedSend) throws
    func delete(walletId: String) throws
}

/// Device-only keychain storage with one entry per wallet, cleared by `Keychain.wipeEntireKeychain`. A backup must not carry
/// these records, so unlike `OnchainSendAttemptStore` this signals no backup change.
struct HwRetainedSendStore: HwRetainedSendStoring {
    func load(walletId: String) throws -> HwRetainedSend? {
        guard let data = try Keychain.load(key: .hwRetainedSend(walletId: walletId)) else { return nil }
        guard let send = try? JSONDecoder().decode(HwRetainedSend.self, from: data) else {
            throw HwRetainedSendError.corruptStore
        }
        return send
    }

    func save(_ send: HwRetainedSend) throws {
        try Keychain.upsert(key: .hwRetainedSend(walletId: send.walletId), data: JSONEncoder().encode(send))
    }

    func delete(walletId: String) throws {
        try Keychain.delete(key: .hwRetainedSend(walletId: walletId))
    }
}

/// Holds at most one retained send per hardware wallet. Every read throws on unreadable storage rather than reporting no
/// record, because a missing record lets the next attempt sign again.
actor HwRetainedSendService {
    static let shared = HwRetainedSendService()

    private let store: any HwRetainedSendStoring

    init(store: any HwRetainedSendStoring = HwRetainedSendStore()) {
        self.store = store
    }

    /// Retaining the bytes already held keeps the existing record, including its `retryWasRefused`.
    func retain(_ send: HwRetainedSend) throws {
        if let existing = try store.load(walletId: send.walletId) {
            guard existing.serializedTx == send.serializedTx else { throw HwRetainedSendError.differentTransactionRetained }
            return
        }
        try store.save(send)
    }

    func record(walletId: String) throws -> HwRetainedSend? {
        try store.load(walletId: walletId)
    }

    func markRetryRefused(walletId: String) throws {
        guard var send = try store.load(walletId: walletId), !send.retryWasRefused else { return }
        send.retryWasRefused = true
        try store.save(send)
    }

    /// Reads first so a corrupt entry throws and stays in place. Only `abandon` may delete one.
    func release(walletId: String) throws {
        guard try store.load(walletId: walletId) != nil else { return }
        try store.delete(walletId: walletId)
    }

    /// Only for a user who accepted a second payment. This is the one path that deletes a corrupt entry, otherwise the wallet
    /// stays blocked until a full wipe. A failed read deletes nothing, because it says nothing about the stored data and may
    /// recover on its own.
    func abandon(walletId: String) throws {
        do {
            try release(walletId: walletId)
        } catch HwRetainedSendError.corruptStore {
            try store.delete(walletId: walletId)
        }
    }

    /// Releases the wallet's record when one of `txIds` is its transaction.
    func releaseIfObserved(walletId: String, txIds: [String]) throws {
        guard let send = try store.load(walletId: walletId), let txid = try? SignedTransactionId.fromHex(send.serializedTx),
              txIds.contains(where: { $0.caseInsensitiveCompare(txid) == .orderedSame })
        else { return }
        try release(walletId: walletId)
    }
}
