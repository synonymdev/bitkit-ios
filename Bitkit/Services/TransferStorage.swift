import Combine
import Foundation

/// Handles persistence of Transfer objects using UserDefaults
class TransferStorage {
    static let shared = TransferStorage()

    private let defaults: UserDefaults
    private let transfersKey = "transfers"

    private let transfersChangedSubject = PassthroughSubject<Void, Never>()

    var transfersChangedPublisher: AnyPublisher<Void, Never> {
        transfersChangedSubject.eraseToAnyPublisher()
    }

    private init(suiteName: String? = nil) {
        if let suiteName {
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            defaults = .standard
        }
    }

    /// Insert a new transfer
    func insert(_ transfer: Transfer) throws {
        var transfers = try getAll()
        transfers.append(transfer)
        try save(transfers)
        Logger.info("Inserted transfer: id=\(transfer.id) type=\(transfer.type)", context: "TransferStorage")
        transfersChangedSubject.send()
    }

    /// Update an existing transfer
    func update(_ transfer: Transfer) throws {
        var transfers = try getAll()
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
            try save(transfers)
            Logger.info("Updated transfer: id=\(transfer.id)", context: "TransferStorage")
            transfersChangedSubject.send()
        }
    }

    /// Upsert a list of transfers (insert or update)
    func upsertList(_ transfers: [Transfer]) throws {
        var allTransfers = try getAll()
        var hasChanges = false

        for transfer in transfers {
            if let index = allTransfers.firstIndex(where: { $0.id == transfer.id }) {
                // Update existing
                allTransfers[index] = transfer
                hasChanges = true
            } else {
                // Insert new
                allTransfers.append(transfer)
                hasChanges = true
            }
        }

        if hasChanges {
            try save(allTransfers)
            Logger.info("Upserted \(transfers.count) transfers", context: "TransferStorage")
            transfersChangedSubject.send()
        }
    }

    /// Get all active (unsettled) transfers
    func getActiveTransfers() throws -> [Transfer] {
        let transfers = try getAll()
        return transfers.filter { !$0.isSettled }
    }

    /// Get a transfer by ID
    func getById(_ id: String) throws -> Transfer? {
        let transfers = try getAll()
        return transfers.first { $0.id == id }
    }

    /// Mark a transfer as settled
    func markSettled(id: String, settledAt: UInt64) throws {
        var transfers = try getAll()
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            let transfer = transfers[index]
            transfers[index] = Transfer(
                id: transfer.id,
                type: transfer.type,
                amountSats: transfer.amountSats,
                channelId: transfer.channelId,
                fundingTxId: transfer.fundingTxId,
                lspOrderId: transfer.lspOrderId,
                isSettled: true,
                createdAt: transfer.createdAt,
                settledAt: settledAt,
                claimableAtHeight: transfer.claimableAtHeight
            )
            try save(transfers)
            Logger.info("Marked transfer as settled: id=\(id)", context: "TransferStorage")
            transfersChangedSubject.send()
        }
    }

    /// Delete old settled transfers
    func deleteOldSettled(expirationTimestamp: UInt64) throws {
        var transfers = try getAll()
        let originalCount = transfers.count
        transfers.removeAll { transfer in
            transfer.isSettled && (transfer.settledAt ?? 0) < expirationTimestamp
        }

        if transfers.count != originalCount {
            try save(transfers)
            Logger.info("Deleted \(originalCount - transfers.count) old settled transfers", context: "TransferStorage")
            transfersChangedSubject.send()
        }
    }

    func getAll() throws -> [Transfer] {
        guard let data = defaults.data(forKey: transfersKey) else {
            return []
        }

        let decoder = JSONDecoder()
        return try decoder.decode([Transfer].self, from: data)
    }

    // MARK: - Private Helpers

    private func save(_ transfers: [Transfer]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(transfers)
        defaults.set(data, forKey: transfersKey)
    }
}
