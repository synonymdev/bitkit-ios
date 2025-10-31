import Foundation

/// Handles persistence of Transfer objects using UserDefaults
class TransferStorage {
    private let defaults: UserDefaults
    private let transfersKey = "transfers"

    init(suiteName: String? = nil) {
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
    }

    /// Update an existing transfer
    func update(_ transfer: Transfer) throws {
        var transfers = try getAll()
        if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
            transfers[index] = transfer
            try save(transfers)
            Logger.info("Updated transfer: id=\(transfer.id)", context: "TransferStorage")
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
            var transfer = transfers[index]
            transfer = Transfer(
                id: transfer.id,
                type: transfer.type,
                amountSats: transfer.amountSats,
                channelId: transfer.channelId,
                fundingTxId: transfer.fundingTxId,
                lspOrderId: transfer.lspOrderId,
                isSettled: true,
                createdAt: transfer.createdAt,
                settledAt: settledAt
            )
            transfers[index] = transfer
            try save(transfers)
            Logger.info("Marked transfer as settled: id=\(id)", context: "TransferStorage")
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
        }
    }

    // MARK: - Private Helpers

    private func getAll() throws -> [Transfer] {
        guard let data = defaults.data(forKey: transfersKey) else {
            return []
        }

        let decoder = JSONDecoder()
        return try decoder.decode([Transfer].self, from: data)
    }

    private func save(_ transfers: [Transfer]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(transfers)
        defaults.set(data, forKey: transfersKey)
    }
}
