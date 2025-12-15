// PaykitReceiptStore.swift
// Bitkit iOS - Paykit Integration
//
// Persistent receipt storage using UserDefaults.

import Foundation

// MARK: - PaykitReceiptStore

/// Persistent receipt store using UserDefaults.
///
/// Provides thread-safe storage and retrieval of payment receipts.
/// Receipts are automatically persisted to disk and survive app restarts.
public final class PaykitReceiptStore {
    
    // MARK: - Constants
    
    private static let storageKey = "com.bitkit.paykit.receipts"
    private static let maxReceipts = 1000  // Prevent unbounded growth
    
    // MARK: - Properties
    
    private let defaults: UserDefaults
    private var cache: [String: PaykitReceipt] = [:]
    private let queue = DispatchQueue(label: "PaykitReceiptStore", attributes: .concurrent)
    private var isLoaded = false
    
    // MARK: - Initialization
    
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDisk()
    }
    
    // MARK: - Public Methods
    
    /// Store a receipt (persisted to disk).
    public func store(_ receipt: PaykitReceipt) {
        queue.async(flags: .barrier) {
            self.cache[receipt.id] = receipt
            self.saveToDisk()
        }
    }
    
    /// Get receipt by ID.
    public func get(id: String) -> PaykitReceipt? {
        queue.sync {
            cache[id]
        }
    }
    
    /// Get all receipts, sorted by timestamp (newest first).
    public func getAll() -> [PaykitReceipt] {
        queue.sync {
            Array(cache.values).sorted { $0.timestamp > $1.timestamp }
        }
    }
    
    /// Get receipts filtered by type.
    public func getByType(_ type: PaykitReceiptType) -> [PaykitReceipt] {
        queue.sync {
            cache.values.filter { $0.type == type }.sorted { $0.timestamp > $1.timestamp }
        }
    }
    
    /// Get receipts filtered by status.
    public func getByStatus(_ status: PaykitReceiptStatus) -> [PaykitReceipt] {
        queue.sync {
            cache.values.filter { $0.status == status }.sorted { $0.timestamp > $1.timestamp }
        }
    }
    
    /// Update receipt status.
    public func updateStatus(id: String, status: PaykitReceiptStatus) {
        queue.async(flags: .barrier) {
            if var receipt = self.cache[id] {
                receipt.status = status
                self.cache[id] = receipt
                self.saveToDisk()
            }
        }
    }
    
    /// Delete a receipt.
    public func delete(id: String) {
        queue.async(flags: .barrier) {
            self.cache.removeValue(forKey: id)
            self.saveToDisk()
        }
    }
    
    /// Clear all receipts.
    public func clear() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
            self.defaults.removeObject(forKey: Self.storageKey)
        }
    }
    
    /// Get receipt count.
    public var count: Int {
        queue.sync { cache.count }
    }
    
    // MARK: - Persistence
    
    private func loadFromDisk() {
        queue.async(flags: .barrier) {
            guard !self.isLoaded else { return }
            
            if let data = self.defaults.data(forKey: Self.storageKey) {
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let receipts = try decoder.decode([PaykitReceipt].self, from: data)
                    self.cache = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0) })
                    Logger.debug("Loaded \(receipts.count) receipts from disk", context: "PaykitReceiptStore")
                } catch {
                    Logger.error("Failed to load receipts: \(error)", context: "PaykitReceiptStore")
                }
            }
            
            self.isLoaded = true
        }
    }
    
    private func saveToDisk() {
        // Called within barrier, no need for additional synchronization
        do {
            // Trim old receipts if we exceed max
            if cache.count > Self.maxReceipts {
                let sorted = cache.values.sorted { $0.timestamp > $1.timestamp }
                let toKeep = Array(sorted.prefix(Self.maxReceipts))
                cache = Dictionary(uniqueKeysWithValues: toKeep.map { ($0.id, $0) })
            }
            
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Array(cache.values))
            defaults.set(data, forKey: Self.storageKey)
            Logger.debug("Saved \(cache.count) receipts to disk", context: "PaykitReceiptStore")
        } catch {
            Logger.error("Failed to save receipts: \(error)", context: "PaykitReceiptStore")
        }
    }
}
