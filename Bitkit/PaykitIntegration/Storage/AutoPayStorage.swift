//
//  AutoPayStorage.swift
//  Bitkit
//
//  Persistent storage for auto-pay settings using Keychain.
//

import Foundation

/// A peer-specific spending limit (stored in Keychain)
public struct StoredPeerLimit: Identifiable, Codable {
    public let id: String
    public var peerPubkey: String
    public var peerName: String
    public var limitSats: Int64
    public var spentSats: Int64
    public var period: String  // daily, weekly, monthly
    public var lastResetDate: Date
    
    public init(peerPubkey: String, peerName: String, limitSats: Int64, period: String = "daily") {
        self.id = peerPubkey
        self.peerPubkey = peerPubkey
        self.peerName = peerName
        self.limitSats = limitSats
        self.spentSats = 0
        self.period = period
        self.lastResetDate = Date()
    }
    
    public mutating func resetIfNeeded() {
        let calendar = Calendar.current
        let shouldReset: Bool
        
        switch period.lowercased() {
        case "daily":
            shouldReset = !calendar.isDateInToday(lastResetDate)
        case "weekly":
            shouldReset = !calendar.isDate(lastResetDate, equalTo: Date(), toGranularity: .weekOfYear)
        case "monthly":
            shouldReset = !calendar.isDate(lastResetDate, equalTo: Date(), toGranularity: .month)
        default:
            shouldReset = false
        }
        
        if shouldReset {
            spentSats = 0
            lastResetDate = Date()
        }
    }
    
    public var remainingSats: Int64 {
        max(0, limitSats - spentSats)
    }
    
    public var usagePercent: Double {
        guard limitSats > 0 else { return 0 }
        return Double(spentSats) / Double(limitSats) * 100
    }
}

/// An auto-pay rule (stored in Keychain)
public struct StoredAutoPayRule: Identifiable, Codable {
    public let id: String
    public var name: String
    public var isEnabled: Bool
    public var maxAmountSats: Int64?
    public var allowedMethods: [String]
    public var allowedPeers: [String]  // Empty = all peers
    public var requireConfirmation: Bool
    public let createdAt: Date
    
    public init(
        name: String,
        maxAmountSats: Int64? = nil,
        allowedMethods: [String] = [],
        allowedPeers: [String] = []
    ) {
        self.id = UUID().uuidString
        self.name = name
        self.isEnabled = true
        self.maxAmountSats = maxAmountSats
        self.allowedMethods = allowedMethods
        self.allowedPeers = allowedPeers
        self.requireConfirmation = false
        self.createdAt = Date()
    }
    
    public func matches(amount: Int64, method: String, peer: String) -> Bool {
        guard isEnabled else { return false }
        
        // Check amount
        if let max = maxAmountSats, amount > max {
            return false
        }
        
        // Check method
        if !allowedMethods.isEmpty && !allowedMethods.contains(method) {
            return false
        }
        
        // Check peer
        if !allowedPeers.isEmpty && !allowedPeers.contains(peer) {
            return false
        }
        
        return true
    }
}

/// Manages persistent storage of auto-pay settings
public class AutoPayStorage {
    
    // MARK: - Singleton
    
    public static let shared = AutoPayStorage()
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    // In-memory cache
    private var settingsCache: AutoPaySettings?
    private var limitsCache: [StoredPeerLimit]?
    private var rulesCache: [StoredAutoPayRule]?
    private var historyCache: [AutoPayHistoryEntry]?
    
    private var settingsKey: String {
        "paykit.autopay.\(identityName).settings"
    }
    
    private var limitsKey: String {
        "paykit.autopay.\(identityName).limits"
    }
    
    private var rulesKey: String {
        "paykit.autopay.\(identityName).rules"
    }
    
    private var historyKey: String {
        "paykit.autopay.\(identityName).history"
    }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - Convenience
    
    /// Whether auto-pay is globally enabled
    public var isEnabled: Bool {
        getSettings().isEnabled
    }
    
    /// Get an auto-pay rule for a specific peer
    public func getRule(for peerPubkey: String) -> StoredAutoPayRule? {
        getRules().first { rule in
            rule.isEnabled && (rule.allowedPeers.isEmpty || rule.allowedPeers.contains(peerPubkey))
        }
    }
    
    // MARK: - Settings
    
    public func getSettings() -> AutoPaySettings {
        if let cached = settingsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: settingsKey) else {
                return AutoPaySettings.defaults
            }
            let settings = try JSONDecoder().decode(AutoPaySettings.self, from: data)
            settingsCache = settings
            return settings
        } catch {
            Logger.error("AutoPayStorage: Failed to load settings: \(error)", context: "AutoPayStorage")
            return AutoPaySettings.defaults
        }
    }
    
    public func saveSettings(_ settings: AutoPaySettings) throws {
        let data = try JSONEncoder().encode(settings)
        try keychain.store(key: settingsKey, data: data)
        settingsCache = settings
    }
    
    // MARK: - Peer Limits
    
    public func getPeerLimits() -> [StoredPeerLimit] {
        if var cached = limitsCache {
            for i in cached.indices {
                cached[i].resetIfNeeded()
            }
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: limitsKey) else {
                return []
            }
            var limits = try JSONDecoder().decode([StoredPeerLimit].self, from: data)
            for i in limits.indices {
                limits[i].resetIfNeeded()
            }
            limitsCache = limits
            return limits
        } catch {
            Logger.error("AutoPayStorage: Failed to load limits: \(error)", context: "AutoPayStorage")
            return []
        }
    }
    
    public func savePeerLimit(_ limit: StoredPeerLimit) throws {
        var limits = getPeerLimits()
        if let index = limits.firstIndex(where: { $0.id == limit.id }) {
            limits[index] = limit
        } else {
            limits.append(limit)
        }
        try persistLimits(limits)
    }
    
    public func deletePeerLimit(id: String) throws {
        var limits = getPeerLimits()
        limits.removeAll { $0.id == id }
        try persistLimits(limits)
    }
    
    // MARK: - Rules
    
    public func getRules() -> [StoredAutoPayRule] {
        if let cached = rulesCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: rulesKey) else {
                return []
            }
            let rules = try JSONDecoder().decode([StoredAutoPayRule].self, from: data)
            rulesCache = rules
            return rules
        } catch {
            Logger.error("AutoPayStorage: Failed to load rules: \(error)", context: "AutoPayStorage")
            return []
        }
    }
    
    public func saveRule(_ rule: StoredAutoPayRule) throws {
        var rules = getRules()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        try persistRules(rules)
    }
    
    public func deleteRule(id: String) throws {
        var rules = getRules()
        rules.removeAll { $0.id == id }
        try persistRules(rules)
    }
    
    // MARK: - History
    
    public func getHistory() -> [AutoPayHistoryEntry] {
        if let cached = historyCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: historyKey) else {
                return []
            }
            let history = try JSONDecoder().decode([AutoPayHistoryEntry].self, from: data)
            historyCache = history.sorted { $0.timestamp > $1.timestamp }
            return historyCache!
        } catch {
            Logger.error("AutoPayStorage: Failed to load history: \(error)", context: "AutoPayStorage")
            return []
        }
    }
    
    public func saveHistoryEntry(_ entry: AutoPayHistoryEntry) throws {
        var history = getHistory()
        history.insert(entry, at: 0)
        
        // Keep only the last 100 entries
        if history.count > 100 {
            history = Array(history.prefix(100))
        }
        
        try persistHistory(history)
    }
    
    public func clearHistory() throws {
        try persistHistory([])
    }
    
    // MARK: - Private
    
    private func persistLimits(_ limits: [StoredPeerLimit]) throws {
        let data = try JSONEncoder().encode(limits)
        try keychain.store(key: limitsKey, data: data)
        limitsCache = limits
    }
    
    private func persistRules(_ rules: [StoredAutoPayRule]) throws {
        let data = try JSONEncoder().encode(rules)
        try keychain.store(key: rulesKey, data: data)
        rulesCache = rules
    }
    
    private func persistHistory(_ history: [AutoPayHistoryEntry]) throws {
        let data = try JSONEncoder().encode(history)
        try keychain.store(key: historyKey, data: data)
        historyCache = history
    }
}

