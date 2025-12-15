//
//  ReceiptStorage.swift
//  Bitkit
//
//  Persistent storage for receipts using Keychain.
//

import Foundation

/// Manages persistent storage of payment receipts
public class ReceiptStorage {
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    private let maxReceiptsToKeep = 500  // Limit stored receipts
    
    // In-memory cache
    private var receiptsCache: [PaymentReceipt]?
    
    private var receiptsKey: String {
        "paykit.receipts.\(identityName)"
    }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - CRUD Operations
    
    /// Get all receipts (newest first)
    public func listReceipts() -> [PaymentReceipt] {
        if let cached = receiptsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: receiptsKey) else {
                return []
            }
            var receipts = try JSONDecoder().decode([PaymentReceipt].self, from: data)
            // Sort by date, newest first
            receipts.sort { $0.createdAt > $1.createdAt }
            receiptsCache = receipts
            return receipts
        } catch {
            Logger.error("ReceiptStorage: Failed to load receipts: \(error)", context: "ReceiptStorage")
            return []
        }
    }
    
    /// Get receipts filtered by status
    public func listReceipts(status: PaymentReceiptStatus) -> [PaymentReceipt] {
        return listReceipts().filter { $0.status == status }
    }
    
    /// Get receipts filtered by direction
    public func listReceipts(direction: PaymentDirection) -> [PaymentReceipt] {
        return listReceipts().filter { $0.direction == direction }
    }
    
    /// Get recent receipts (limited count)
    public func recentReceipts(limit: Int = 10) -> [PaymentReceipt] {
        return Array(listReceipts().prefix(limit))
    }
    
    /// Get a specific receipt
    public func getPaymentReceipt(id: String) -> PaymentReceipt? {
        return listReceipts().first { $0.id == id }
    }
    
    /// Add a new receipt
    public func addPaymentReceipt(_ receipt: PaymentReceipt) throws {
        var receipts = listReceipts()
        
        // Add new receipt at the beginning (newest first)
        receipts.insert(receipt, at: 0)
        
        // Trim to max size
        if receipts.count > maxReceiptsToKeep {
            receipts = Array(receipts.prefix(maxReceiptsToKeep))
        }
        
        try persistReceipts(receipts)
    }
    
    /// Update an existing receipt
    public func updatePaymentReceipt(_ receipt: PaymentReceipt) throws {
        var receipts = listReceipts()
        
        guard let index = receipts.firstIndex(where: { $0.id == receipt.id }) else {
            throw PaykitStorageError.notFound(id: receipt.id)
        }
        
        receipts[index] = receipt
        try persistReceipts(receipts)
    }
    
    /// Delete a receipt
    public func deletePaymentReceipt(id: String) throws {
        var receipts = listReceipts()
        receipts.removeAll { $0.id == id }
        try persistReceipts(receipts)
    }
    
    /// Search receipts by counterparty or memo
    public func searchReceipts(query: String) -> [PaymentReceipt] {
        let query = query.lowercased()
        return listReceipts().filter { receipt in
            receipt.displayName.lowercased().contains(query) ||
            receipt.counterpartyKey.lowercased().contains(query) ||
            (receipt.memo?.lowercased().contains(query) ?? false)
        }
    }
    
    /// Get receipts for a specific counterparty
    public func receiptsForCounterparty(publicKey: String) -> [PaymentReceipt] {
        return listReceipts().filter { $0.counterpartyKey == publicKey }
    }
    
    /// Clear all receipts
    public func clearAll() throws {
        try persistReceipts([])
    }
    
    // MARK: - Statistics
    
    /// Total sent amount
    public func totalSent() -> UInt64 {
        return listReceipts(direction: .sent)
            .filter { $0.status == .completed }
            .reduce(0) { $0 + $1.amountSats }
    }
    
    /// Total received amount
    public func totalReceived() -> UInt64 {
        return listReceipts(direction: .received)
            .filter { $0.status == .completed }
            .reduce(0) { $0 + $1.amountSats }
    }
    
    /// Count of completed transactions
    public func completedCount() -> Int {
        return listReceipts(status: .completed).count
    }
    
    /// Count of pending transactions
    public func pendingCount() -> Int {
        return listReceipts(status: .pending).count
    }
    
    // MARK: - Private
    
    private func persistReceipts(_ receipts: [PaymentReceipt]) throws {
        let data = try JSONEncoder().encode(receipts)
        try keychain.store(key: receiptsKey, data: data)
        receiptsCache = receipts
    }
}

extension PaykitStorageError {
    static func notFound(id: String) -> PaykitStorageError {
        return .loadFailed(key: id)
    }
}

