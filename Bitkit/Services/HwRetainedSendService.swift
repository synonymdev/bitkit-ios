import Foundation

/// A signed ordinary hardware-wallet send whose broadcast may have gone out. Rebroadcasting these same bytes cannot pay
/// twice, because the txid stays the same, while a new signature can create a second payment.
/// `serializedTx` reveals the payment, so never log it or this record.
struct HwRetainedSend: Codable, Equatable {
    let walletId: String
    let address: String
    let sats: UInt64
    let satsPerVByte: UInt64
    let serializedTx: String
    let miningFeeSats: UInt64
    let feeRate: Float
    let totalSpent: UInt64
    var retryWasRefused = false
}

enum HwRetainedSendError: Error {
    case differentTransactionRetained
}

protocol HwRetainedSendStoring: Sendable {
    func load() throws -> [String: HwRetainedSend]
    func save(_ sends: [String: HwRetainedSend]) throws
}

/// Device-only keychain storage, cleared by `Keychain.wipeEntireKeychain`. A backup must not carry these records, so unlike
/// `OnchainSendAttemptStore` this signals no backup change.
struct HwRetainedSendStore: HwRetainedSendStoring {
    func load() throws -> [String: HwRetainedSend] {
        guard let data = try Keychain.load(key: .hwRetainedSends) else { return [:] }
        return try JSONDecoder().decode([String: HwRetainedSend].self, from: data)
    }

    func save(_ sends: [String: HwRetainedSend]) throws {
        try Keychain.upsert(key: .hwRetainedSends, data: JSONEncoder().encode(sends))
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
        var sends = try store.load()
        if let existing = sends[send.walletId] {
            guard existing.serializedTx == send.serializedTx else { throw HwRetainedSendError.differentTransactionRetained }
            return
        }
        sends[send.walletId] = send
        try store.save(sends)
    }

    func record(walletId: String) throws -> HwRetainedSend? {
        try store.load()[walletId]
    }

    func markRetryRefused(walletId: String) throws {
        var sends = try store.load()
        guard sends[walletId]?.retryWasRefused == false else { return }
        sends[walletId]?.retryWasRefused = true
        try store.save(sends)
    }

    func release(walletId: String) throws {
        var sends = try store.load()
        guard sends.removeValue(forKey: walletId) != nil else { return }
        try store.save(sends)
    }

    /// Releases the wallet's record when one of `txIds` is its transaction. Returns whether it released one.
    @discardableResult
    func releaseIfObserved(walletId: String, txIds: [String]) throws -> Bool {
        var sends = try store.load()
        guard let send = sends[walletId], let txid = try? SignedTransactionId.fromHex(send.serializedTx),
              txIds.contains(where: { $0.caseInsensitiveCompare(txid) == .orderedSame })
        else { return false }
        sends[walletId] = nil
        try store.save(sends)
        return true
    }
}
