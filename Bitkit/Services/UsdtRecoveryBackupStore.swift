import BitkitCore
import CryptoKit
import Foundation

struct UsdtRecoveryBackupV1: Codable {
    let version: Int
    let usdtWallet: String
    let paykitUsdtState: PaykitUsdtStateBackup
}

/// Immutable, encrypted VSS records. VSS's unconditional writes cannot safely replace a shared
/// recovery snapshot: concurrent devices may know different signed operations. Content-addressed
/// records also make retrying an upload with a lost acknowledgement idempotent. Do not prune records
/// until a compaction protocol can prove every writer's recovery data remains acknowledged.
struct UsdtRecoveryBackupStore {
    static let prefix = "USDT_RECOVERY_"
    private static let versionPrefix = prefix + "V1_"

    var put: (String, Data) async throws -> Void = { key, data in
        _ = try await VssBackupClient.shared.putObject(key: key, data: data)
    }

    var keys: () async throws -> [String] = { try await VssBackupClient.shared.listKeys() }
    var get: (String) async throws -> Data? = { try await VssBackupClient.shared.getObject(key: $0)?.value }

    func persist(snapshot: String, paymentState: PaykitUsdtStateBackup) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(UsdtRecoveryBackupV1(version: 1, usdtWallet: snapshot, paykitUsdtState: paymentState))
        try await put(Self.key(for: data), data)
    }

    func snapshots() async throws -> [UsdtRecoveryBackupV1] {
        // VSS obfuscates whole keys; passing a plaintext prefix to its listing API is not a prefix scan.
        let recoveryKeys = try await keys().filter { $0.hasPrefix(Self.prefix) }.sorted()
        var snapshots: [UsdtRecoveryBackupV1] = []
        for key in recoveryKeys {
            try Task.checkCancellation()
            guard key.hasPrefix(Self.versionPrefix), let data = try await get(key), Self.key(for: data) == key else {
                throw UsdtError.InvalidBackup
            }
            let snapshot = try JSONDecoder().decode(UsdtRecoveryBackupV1.self, from: data)
            guard snapshot.version == 1 else { throw UsdtError.InvalidBackup }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    func restore(
        legacyWallet: String?,
        legacyPaymentState: PaykitUsdtStateBackup?,
        restoreWallet: (String) async throws -> Void,
        restorePayments: (PaykitUsdtStateBackup) async throws -> Void
    ) async throws {
        let records = try await snapshots()
        if let legacyWallet {
            try await restoreWallet(legacyWallet)
        }
        if let legacyPaymentState {
            try await restorePayments(legacyPaymentState)
        }
        for record in records {
            try await restoreWallet(record.usdtWallet)
            try await restorePayments(record.paykitUsdtState)
        }
    }

    private static func key(for data: Data) -> String {
        versionPrefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum UsdtRecoveryRestoreGate {
    static var isPending: Bool {
        do { return try Keychain.load(key: .usdtPendingBackupRestore) != nil }
        catch { return true }
    }

    @discardableResult
    static func begin() throws -> Data? {
        if let retained = try Keychain.load(key: .usdtPendingBackupRestore) {
            return retained.isEmpty ? nil : retained
        }
        try Keychain.upsert(key: .usdtPendingBackupRestore, data: Data())
        return nil
    }

    static func retain(_ legacyWallet: Data) throws {
        try Keychain.upsert(key: .usdtPendingBackupRestore, data: legacyWallet)
    }

    static func complete() throws {
        try Keychain.delete(key: .usdtPendingBackupRestore)
    }
}
