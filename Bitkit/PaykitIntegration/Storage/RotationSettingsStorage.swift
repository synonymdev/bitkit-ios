//
//  RotationSettingsStorage.swift
//  Bitkit
//
//  Storage for endpoint rotation configuration and history.
//

import Foundation

/// Rotation policy types
public enum RotationPolicy: String, Codable, CaseIterable, Identifiable {
    case onUse = "on-use"
    case afterUses = "after-uses"
    case manual = "manual"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .onUse: return "Rotate on every use"
        case .afterUses: return "Rotate after N uses"
        case .manual: return "Manual only"
        }
    }
    
    public var description: String {
        switch self {
        case .onUse: return "Best privacy - new endpoint after each payment"
        case .afterUses: return "Rotate after a specified number of uses"
        case .manual: return "Only rotate when manually triggered"
        }
    }
}

/// Rotation settings for a specific method
public struct MethodRotationSettings: Codable, Equatable {
    public var policy: RotationPolicy
    public var threshold: Int // For afterUses policy
    public var useCount: Int
    public var lastRotated: Date?
    public var rotationCount: Int
    
    public init(policy: RotationPolicy = .onUse, threshold: Int = 5) {
        self.policy = policy
        self.threshold = threshold
        self.useCount = 0
        self.lastRotated = nil
        self.rotationCount = 0
    }
}

/// Global rotation settings
public struct RotationSettings: Codable {
    public var autoRotateEnabled: Bool
    public var defaultPolicy: RotationPolicy
    public var defaultThreshold: Int
    public var methodSettings: [String: MethodRotationSettings]
    
    public init() {
        self.autoRotateEnabled = true
        self.defaultPolicy = .onUse
        self.defaultThreshold = 5
        self.methodSettings = [:]
    }
}

/// Rotation event for history tracking
public struct RotationEvent: Codable, Identifiable {
    public let id: UUID
    public let methodId: String
    public let timestamp: Date
    public let reason: String
    
    public init(methodId: String, reason: String) {
        self.id = UUID()
        self.methodId = methodId
        self.timestamp = Date()
        self.reason = reason
    }
}

/// Manages rotation settings and history persistence
public class RotationSettingsStorage {
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    private var settingsKey: String {
        "paykit.rotation_settings.\(identityName)"
    }
    
    private var historyKey: String {
        "paykit.rotation_history.\(identityName)"
    }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - Settings
    
    public func loadSettings() -> RotationSettings {
        do {
            guard let data = try keychain.retrieve(key: settingsKey) else {
                return RotationSettings()
            }
            return try JSONDecoder().decode(RotationSettings.self, from: data)
        } catch {
            Logger.error("RotationSettingsStorage: Failed to load settings: \(error)", context: "RotationSettingsStorage")
            return RotationSettings()
        }
    }
    
    public func saveSettings(_ settings: RotationSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try keychain.store(key: settingsKey, data: data)
    }
    
    public func getMethodSettings(_ methodId: String) -> MethodRotationSettings {
        let settings = loadSettings()
        return settings.methodSettings[methodId] ?? MethodRotationSettings(
            policy: settings.defaultPolicy,
            threshold: settings.defaultThreshold
        )
    }
    
    public func updateMethodSettings(_ methodId: String, _ methodSettings: MethodRotationSettings) throws {
        var settings = loadSettings()
        settings.methodSettings[methodId] = methodSettings
        try saveSettings(settings)
    }
    
    // MARK: - Use Tracking
    
    /// Record a payment use for a method
    /// Returns true if rotation should occur
    public func recordUse(methodId: String) throws -> Bool {
        var settings = loadSettings()
        var methodSettings = settings.methodSettings[methodId] ?? MethodRotationSettings(
            policy: settings.defaultPolicy,
            threshold: settings.defaultThreshold
        )
        
        guard settings.autoRotateEnabled else {
            return false
        }
        
        methodSettings.useCount += 1
        settings.methodSettings[methodId] = methodSettings
        try saveSettings(settings)
        
        switch methodSettings.policy {
        case .onUse:
            return true
        case .afterUses:
            return methodSettings.useCount >= methodSettings.threshold
        case .manual:
            return false
        }
    }
    
    /// Record that a rotation occurred
    public func recordRotation(methodId: String, reason: String) throws {
        var settings = loadSettings()
        var methodSettings = settings.methodSettings[methodId] ?? MethodRotationSettings(
            policy: settings.defaultPolicy,
            threshold: settings.defaultThreshold
        )
        
        methodSettings.useCount = 0
        methodSettings.lastRotated = Date()
        methodSettings.rotationCount += 1
        
        settings.methodSettings[methodId] = methodSettings
        try saveSettings(settings)
        
        // Add to history
        try addHistoryEvent(RotationEvent(methodId: methodId, reason: reason))
    }
    
    // MARK: - History
    
    public func loadHistory() -> [RotationEvent] {
        do {
            guard let data = try keychain.retrieve(key: historyKey) else {
                return []
            }
            let events = try JSONDecoder().decode([RotationEvent].self, from: data)
            return events.sorted { $0.timestamp > $1.timestamp }
        } catch {
            Logger.error("RotationSettingsStorage: Failed to load history: \(error)", context: "RotationSettingsStorage")
            return []
        }
    }
    
    private func addHistoryEvent(_ event: RotationEvent) throws {
        var history = loadHistory()
        history.insert(event, at: 0)
        
        // Keep only last 100 events
        if history.count > 100 {
            history = Array(history.prefix(100))
        }
        
        let data = try JSONEncoder().encode(history)
        try keychain.store(key: historyKey, data: data)
    }
    
    public func clearHistory() throws {
        try keychain.delete(key: historyKey)
    }
    
    // MARK: - Statistics
    
    public func totalRotations() -> Int {
        let settings = loadSettings()
        return settings.methodSettings.values.reduce(0) { $0 + $1.rotationCount }
    }
    
    public func methodsWithRotations() -> [String] {
        let settings = loadSettings()
        return settings.methodSettings.filter { $0.value.rotationCount > 0 }.map { $0.key }
    }
}

