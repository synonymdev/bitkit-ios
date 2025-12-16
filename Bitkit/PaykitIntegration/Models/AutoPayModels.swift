//
//  AutoPayModels.swift
//  Bitkit
//
//  Data models for auto-pay functionality
//

import Foundation

public enum SpendingPeriod: String, Codable, CaseIterable {
    case hourly = "Hourly"
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
    
    public var seconds: Int64 {
        switch self {
        case .hourly: return 3600
        case .daily: return 86400
        case .weekly: return 604800
        case .monthly: return 2592000
        }
    }
}

public struct PeerSpendingLimit: Identifiable, Codable {
    public let id: String
    public let peerPubkey: String
    public let peerName: String
    public var limit: Int64
    public var used: Int64
    public let period: SpendingPeriod
    public let periodStart: Date
    
    public var remaining: Int64 { max(0, limit - used) }
    public var percentUsed: Double { guard limit > 0 else { return 0 }; return Double(used) / Double(limit) }
    public var isExhausted: Bool { used >= limit }
    
    public mutating func reset() { used = 0 }
    public func shouldReset(now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(periodStart)
        return elapsed >= Double(period.seconds)
    }
}

public struct AutoPayRule: Identifiable, Codable {
    public let id: String
    public var name: String
    public var description: String
    public var isEnabled: Bool
    public var maxAmount: Int64?
    public var methodFilter: String?
    public var peerFilter: String?
    
    public func matches(peerPubkey: String, amount: Int64, methodId: String) -> Bool {
        if let max = maxAmount, amount > max { return false }
        if let method = methodFilter, method != methodId { return false }
        if let peer = peerFilter, peer != peerPubkey { return false }
        return isEnabled
    }
}

public struct RecentAutoPayment: Identifiable, Codable {
    public let id: String
    public let peerPubkey: String
    public let peerName: String
    public let amount: Int64
    public let description: String
    public let timestamp: Date
    public let status: PaymentExecutionStatus
    public let ruleId: String?
    
    public var formattedAmount: String { "\(amount) sats" }
    public var formattedTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}

public enum PaymentExecutionStatus: String, Codable {
    case pending, processing, completed, failed
    public var color: String {
        switch self {
        case .pending: return "yellow"
        case .processing: return "blue"
        case .completed: return "green"
        case .failed: return "red"
        }
    }
}

public struct AutoPaySettings: Codable {
    public var isEnabled: Bool
    public var globalDailyLimit: Int64
    public var maxPerPayment: Int64
    public var requireBiometricAbove: Int64?
    
    // Notification preferences
    public var notifyOnPayment: Bool
    public var notifyOnLimitReached: Bool
    public var notifyOnBlocked: Bool
    public var notifyOnNewPeer: Bool
    
    // Confirmation requirements
    public var confirmFirstPayment: Bool
    public var confirmHighValue: Bool
    public var confirmSubscriptions: Bool
    public var biometricForLarge: Bool
    
    public static var defaults: AutoPaySettings {
        AutoPaySettings(
            isEnabled: false,
            globalDailyLimit: 100000,
            maxPerPayment: 10000,
            requireBiometricAbove: 10000,
            notifyOnPayment: true,
            notifyOnLimitReached: true,
            notifyOnBlocked: true,
            notifyOnNewPeer: true,
            confirmFirstPayment: true,
            confirmHighValue: true,
            confirmSubscriptions: false,
            biometricForLarge: false
        )
    }
}

public struct SpendingSummary: Codable {
    public let period: SpendingPeriod
    public let periodStart: Date
    public let periodEnd: Date
    public let totalSpent: Int64
    public let totalLimit: Int64
    public let paymentCount: Int
    public let topPeers: [PeerSpending]
    
    public var percentUsed: Double { guard totalLimit > 0 else { return 0 }; return Double(totalSpent) / Double(totalLimit) }
    public var remaining: Int64 { max(0, totalLimit - totalSpent) }
}

public struct PeerSpending: Codable, Identifiable {
    public var id: String { peerPubkey }
    public let peerPubkey: String
    public let peerName: String
    public let amount: Int64
    public let count: Int
}
