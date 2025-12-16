//
//  Subscription.swift
//  Bitkit
//
//  Subscription model for recurring payments
//

import Foundation

/// A stored subscription (distinct from PaykitMobile.Subscription)
public struct BitkitSubscription: Identifiable, Codable {
    public let id: String
    public var providerName: String
    public var providerPubkey: String
    public var amountSats: Int64
    public var currency: String
    public var frequency: String  // daily, weekly, monthly, yearly
    public var description: String
    public var methodId: String
    public var isActive: Bool
    public let createdAt: Date
    public var lastPaymentAt: Date?
    public var nextPaymentAt: Date?
    public var paymentCount: Int
    public var totalSpent: Int64
    public var spendingLimit: SubscriptionSpendingLimit?
    
    public init(
        providerName: String,
        providerPubkey: String,
        amountSats: Int64,
        currency: String = "SAT",
        frequency: String,
        description: String,
        methodId: String = "lightning",
        spendingLimit: SubscriptionSpendingLimit? = nil
    ) {
        self.id = UUID().uuidString
        self.providerName = providerName
        self.providerPubkey = providerPubkey
        self.amountSats = amountSats
        self.currency = currency
        self.frequency = frequency
        self.description = description
        self.methodId = methodId
        self.isActive = true
        self.createdAt = Date()
        self.lastPaymentAt = nil
        self.nextPaymentAt = Self.calculateNextPayment(frequency: frequency, from: Date())
        self.paymentCount = 0
        self.totalSpent = 0
        self.spendingLimit = spendingLimit
    }
    
    public mutating func recordPayment() {
        lastPaymentAt = Date()
        paymentCount += 1
        totalSpent += amountSats
        nextPaymentAt = Self.calculateNextPayment(frequency: frequency, from: Date())
        
        // Update spending limit if present
        if var limit = spendingLimit {
            limit.usedAmount += amountSats
            spendingLimit = limit
        }
    }
    
    public func canMakePayment() -> Bool {
        guard let limit = spendingLimit else { return true }
        return (limit.usedAmount + amountSats) <= limit.maxAmount
    }
    
    public static func calculateNextPayment(frequency: String, from date: Date) -> Date? {
        let calendar = Calendar.current
        switch frequency.lowercased() {
        case "daily":
            return calendar.date(byAdding: .day, value: 1, to: date)
        case "weekly":
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case "monthly":
            return calendar.date(byAdding: .month, value: 1, to: date)
        case "yearly":
            return calendar.date(byAdding: .year, value: 1, to: date)
        default:
            return nil
        }
    }
}
