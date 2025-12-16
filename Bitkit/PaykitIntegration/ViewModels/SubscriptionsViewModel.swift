//
//  SubscriptionsViewModel.swift
//  Bitkit
//
//  ViewModel for Subscriptions management with proposals, payment history, and spending limits
//

import Foundation
import SwiftUI

@MainActor
class SubscriptionsViewModel: ObservableObject {
    @Published var subscriptions: [BitkitSubscription] = []
    @Published var proposals: [SubscriptionProposal] = []
    @Published var paymentHistory: [SubscriptionPayment] = []
    @Published var isLoading = false
    @Published var showingAddSubscription = false
    
    // Spending limit tracking
    @Published var totalSpentThisMonth: Int64 = 0
    @Published var monthlySpendingLimit: Int64 = 1000000 // 1M sats default
    
    var remainingSpendingLimit: Int64 {
        max(0, monthlySpendingLimit - totalSpentThisMonth)
    }
    
    private let subscriptionStorage: SubscriptionStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.subscriptionStorage = SubscriptionStorage(identityName: identityName)
    }
    
    func loadSubscriptions() {
        isLoading = true
        subscriptions = subscriptionStorage.listSubscriptions()
        calculateSpending()
        isLoading = false
    }
    
    func loadProposals() {
        proposals = subscriptionStorage.listProposals()
    }
    
    func loadPaymentHistory() {
        paymentHistory = subscriptionStorage.listPayments()
    }
    
    private func calculateSpending() {
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        
        totalSpentThisMonth = paymentHistory
            .filter { $0.paidAt >= startOfMonth && $0.status == .completed }
            .reduce(0) { $0 + $1.amountSats }
    }
    
    func addSubscription(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.saveSubscription(subscription)
        loadSubscriptions()
    }
    
    func updateSubscription(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.saveSubscription(subscription)
        loadSubscriptions()
    }
    
    func deleteSubscription(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.deleteSubscription(id: subscription.id)
        loadSubscriptions()
    }
    
    func toggleActive(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.toggleActive(id: subscription.id)
        loadSubscriptions()
    }
    
    func recordPayment(_ subscription: BitkitSubscription) throws {
        try subscriptionStorage.recordPayment(subscriptionId: subscription.id)
        loadSubscriptions()
        loadPaymentHistory()
    }
    
    // MARK: - Proposals
    
    func acceptProposal(_ proposal: SubscriptionProposal) throws {
        let subscription = BitkitSubscription(
            providerName: proposal.providerName,
            providerPubkey: proposal.providerPubkey,
            amountSats: proposal.amountSats,
            currency: proposal.currency,
            frequency: proposal.frequency,
            description: proposal.description,
            methodId: proposal.methodId
        )
        
        try subscriptionStorage.saveSubscription(subscription)
        try subscriptionStorage.deleteProposal(id: proposal.id)
        loadSubscriptions()
        loadProposals()
    }
    
    func declineProposal(_ proposal: SubscriptionProposal) throws {
        try subscriptionStorage.deleteProposal(id: proposal.id)
        loadProposals()
    }
    
    // MARK: - Spending Limits
    
    func updateSpendingLimit(_ subscription: BitkitSubscription, limit: SubscriptionSpendingLimit?) throws {
        var updated = subscription
        updated.spendingLimit = limit
        try subscriptionStorage.saveSubscription(updated)
        loadSubscriptions()
    }
    
    func setMonthlySpendingLimit(_ amount: Int64) {
        monthlySpendingLimit = amount
        // Persist this to UserDefaults or dedicated storage
        UserDefaults.standard.set(amount, forKey: "paykit_monthly_spending_limit")
    }
    
    var activeSubscriptions: [BitkitSubscription] {
        subscriptionStorage.activeSubscriptions()
    }
}

// MARK: - Models

struct SubscriptionProposal: Identifiable, Codable {
    let id: String
    let providerName: String
    let providerPubkey: String
    let amountSats: Int64
    let currency: String
    let frequency: String
    let description: String
    let methodId: String
    let maxPayments: Int?
    let startDate: Date?
    let createdAt: Date
    
    init(
        id: String = UUID().uuidString,
        providerName: String,
        providerPubkey: String,
        amountSats: Int64,
        currency: String = "SAT",
        frequency: String,
        description: String = "",
        methodId: String = "lightning",
        maxPayments: Int? = nil,
        startDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.providerName = providerName
        self.providerPubkey = providerPubkey
        self.amountSats = amountSats
        self.currency = currency
        self.frequency = frequency
        self.description = description
        self.methodId = methodId
        self.maxPayments = maxPayments
        self.startDate = startDate
        self.createdAt = createdAt
    }
}

struct SubscriptionPayment: Identifiable, Codable {
    let id: String
    let subscriptionId: String
    let subscriptionName: String
    let amountSats: Int64
    let paidAt: Date
    let status: SubscriptionPaymentStatus
    let txId: String?
    let preimage: String?
    
    init(
        id: String = UUID().uuidString,
        subscriptionId: String,
        subscriptionName: String,
        amountSats: Int64,
        paidAt: Date = Date(),
        status: SubscriptionPaymentStatus = .completed,
        txId: String? = nil,
        preimage: String? = nil
    ) {
        self.id = id
        self.subscriptionId = subscriptionId
        self.subscriptionName = subscriptionName
        self.amountSats = amountSats
        self.paidAt = paidAt
        self.status = status
        self.txId = txId
        self.preimage = preimage
    }
}

enum SubscriptionPaymentStatus: String, Codable {
    case pending = "Pending"
    case completed = "Completed"
    case failed = "Failed"
}

struct SubscriptionSpendingLimit: Codable {
    let maxAmount: Int64
    let period: SpendingLimitPeriod
    var usedAmount: Int64
    let requireConfirmation: Bool
    
    init(maxAmount: Int64, period: SpendingLimitPeriod, usedAmount: Int64 = 0, requireConfirmation: Bool = false) {
        self.maxAmount = maxAmount
        self.period = period
        self.usedAmount = usedAmount
        self.requireConfirmation = requireConfirmation
    }
}

enum SpendingLimitPeriod: String, Codable {
    case daily = "day"
    case weekly = "week"
    case monthly = "month"
}
