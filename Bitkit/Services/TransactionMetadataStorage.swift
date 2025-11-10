import Combine
import Foundation

/// Handles persistence of TransactionMetadata objects using UserDefaults
/// Metadata is temporarily stored until it can be applied to activities during sync
class TransactionMetadataStorage {
    static let shared = TransactionMetadataStorage()

    private let defaults: UserDefaults
    private let metadataKey = "transactionMetadata"

    private let metadataChangedSubject = PassthroughSubject<Void, Never>()

    var metadataChangedPublisher: AnyPublisher<Void, Never> {
        metadataChangedSubject.eraseToAnyPublisher()
    }

    private init(suiteName: String? = nil) {
        if let suiteName {
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            defaults = .standard
        }
    }

    /// Insert a new transaction metadata entry
    func insert(_ metadata: TransactionMetadata) throws {
        var allMetadata = try getAll()

        // Check if metadata for this txId already exists
        if allMetadata.contains(where: { $0.txId == metadata.txId }) {
            Logger.warn("Transaction metadata for \(metadata.txId) already exists, skipping insert", context: "TransactionMetadataStorage")
            return
        }

        allMetadata.append(metadata)
        try save(allMetadata)
        Logger.info("Inserted transaction metadata: txId=\(metadata.txId)", context: "TransactionMetadataStorage")
        metadataChangedSubject.send()
    }

    /// Insert a list of transaction metadata entries (for restore operations)
    func insertList(_ metadataList: [TransactionMetadata]) throws {
        var allMetadata = try getAll()
        var hasChanges = false

        for metadata in metadataList {
            // Only insert if not already present
            if !allMetadata.contains(where: { $0.txId == metadata.txId }) {
                allMetadata.append(metadata)
                hasChanges = true
            }
        }

        if hasChanges {
            try save(allMetadata)
            Logger.info("Inserted \(metadataList.count) transaction metadata entries", context: "TransactionMetadataStorage")
            metadataChangedSubject.send()
        }
    }

    /// Get all stored transaction metadata
    func getAll() throws -> [TransactionMetadata] {
        guard let data = defaults.data(forKey: metadataKey) else {
            return []
        }

        let decoder = JSONDecoder()
        return try decoder.decode([TransactionMetadata].self, from: data)
    }

    /// Remove metadata by transaction ID
    func remove(txId: String) throws {
        var allMetadata = try getAll()
        let originalCount = allMetadata.count

        allMetadata.removeAll { $0.txId == txId }

        if allMetadata.count != originalCount {
            try save(allMetadata)
            Logger.info("Removed transaction metadata: txId=\(txId)", context: "TransactionMetadataStorage")
            metadataChangedSubject.send()
        }
    }

    /// Remove all transaction metadata (for testing or cleanup)
    func removeAll() throws {
        let allMetadata = try getAll()

        if allMetadata.isEmpty {
            return
        }

        defaults.removeObject(forKey: metadataKey)
        Logger.info("Removed all transaction metadata (\(allMetadata.count) entries)", context: "TransactionMetadataStorage")
        metadataChangedSubject.send()
    }

    /// Remove old metadata entries that are older than the specified timestamp
    func removeOld(olderThan timestamp: UInt64) throws {
        var allMetadata = try getAll()
        let originalCount = allMetadata.count

        allMetadata.removeAll { $0.createdAt < timestamp }

        if allMetadata.count != originalCount {
            try save(allMetadata)
            Logger.info("Removed \(originalCount - allMetadata.count) old transaction metadata entries", context: "TransactionMetadataStorage")
            metadataChangedSubject.send()
        }
    }

    // MARK: - Private Helpers

    private func save(_ metadata: [TransactionMetadata]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)
        defaults.set(data, forKey: metadataKey)
    }
}
