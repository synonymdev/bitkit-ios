import CryptoKit
import Foundation

/// The idempotency key of a Spark send of an invoice. Spark makes one transfer per key, so a retry under the same key
/// never pays the invoice twice: it gets back the transfer an earlier try committed, or sends when none did. A key whose
/// payment failed can't send again, so the next attempt takes the next key.
///
/// Keys derive from the wallet seed, the payment hash and the attempt number, so a restored wallet derives the same
/// keys, no other wallet can, and the operators can't link a transfer to its invoice. Android derives the same keys.
enum SparkSendKey {
    private static let namespace = UUID(uuidString: "794acd96-39bc-4fd1-a09f-02b269a4a34d")!
    private static let label = Data("bitkit spark send key".utf8)

    /// The secret all send keys derive from: an HMAC-SHA256 of a fixed label, keyed with the BIP39 `seed`.
    static func secret(seed: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: label, using: SymmetricKey(data: seed)))
    }

    /// The key of attempt `attempt` at paying the invoice with `paymentHash`: a UUIDv5 of `secret`, the hash's 32 bytes
    /// and `attempt` as 4 bytes big-endian.
    static func key(secret: Data, paymentHash: String, attempt: UInt32) -> String {
        var name = secret + paymentHash.hexaData
        withUnsafeBytes(of: attempt.bigEndian) { name.append(contentsOf: $0) }
        var sha1 = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { sha1.update(bufferPointer: $0) }
        sha1.update(data: name)
        var bytes = Array(sha1.finalize().prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return UUID(uuid: uuid).uuidString.lowercased()
    }
}

/// The latest attempt at each invoice Spark sent, by payment hash, whose number picks the attempt's `SparkSendKey`.
enum SparkSendAttempts {
    private static let storageKey = "sparkSendAttempts"
    private static let lock = NSLock()

    private struct Attempt: Codable {
        let attempt: UInt32
        let expiresAt: UInt64
    }

    /// The attempt whose key pays the invoice with `paymentHash`: the latest kept one, past each whose key is in
    /// `failedIds`, the ids of the payments Spark lists as failed, as a failed key can't send again. An attempt Spark
    /// may still commit keeps its key, so a retry gets back its payment instead of paying again.
    static func next(paymentHash: String, secret: Data, failedIds: Set<String>) -> UInt32 {
        var attempt = lock.withLock { stored[paymentHash.lowercased()]?.attempt } ?? 0
        while failedIds.contains(SparkSendKey.key(secret: secret, paymentHash: paymentHash, attempt: attempt)) {
            attempt += 1
        }
        return attempt
    }

    /// The latest attempt kept for the invoice with `paymentHash`, nil before its first.
    static func latest(paymentHash: String) -> UInt32? {
        lock.withLock { stored[paymentHash.lowercased()]?.attempt }
    }

    /// Keeps `attempt` as the latest at the invoice with `paymentHash`, which expires at `expiresAt`, and drops the
    /// attempts of invoices expired before `now`, both in epoch seconds.
    static func set(paymentHash: String, attempt: UInt32, expiresAt: UInt64, now: UInt64) {
        lock.withLock {
            var attempts = stored.filter { $0.value.expiresAt >= now }
            attempts[paymentHash.lowercased()] = Attempt(attempt: attempt, expiresAt: expiresAt)
            stored = attempts
        }
    }

    /// Puts back `attempt`, the latest kept before a send whose key never reached Spark, or drops the invoice's entry
    /// when it had none.
    static func restore(paymentHash: String, attempt: UInt32?, expiresAt: UInt64) {
        lock.withLock {
            var attempts = stored
            attempts[paymentHash.lowercased()] = attempt.map { Attempt(attempt: $0, expiresAt: expiresAt) }
            stored = attempts
        }
    }

    static func clear() {
        lock.withLock { UserDefaults.standard.removeObject(forKey: storageKey) }
    }

    private static var stored: [String: Attempt] {
        get {
            UserDefaults.standard.data(forKey: storageKey)
                .flatMap { try? JSONDecoder().decode([String: Attempt].self, from: $0) } ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }
    }
}
