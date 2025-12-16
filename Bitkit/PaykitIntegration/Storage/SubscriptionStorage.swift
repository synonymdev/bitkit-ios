//
//  SubscriptionStorage.swift
//  Bitkit
//
//  Persistent storage for subscriptions, proposals, and payment history using Keychain.
//

import Foundation

/// Manages persistent storage of subscriptions, proposals, and payment history
public class SubscriptionStorage {
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    // In-memory caches
    private var subscriptionsCache: [BitkitSubscription]?
    private var proposalsCache: [SubscriptionProposal]?
    private var paymentsCache: [SubscriptionPayment]?
    
    private var subscriptionsKey: String { "paykit.subscriptions.\(identityName)" }
    private var proposalsKey: String { "paykit.proposals.\(identityName)" }
    private var paymentsKey: String { "paykit.payments.\(identityName)" }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - Subscriptions CRUD
    
    public func listSubscriptions() -> [BitkitSubscription] {
        if let cached = subscriptionsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: subscriptionsKey) else {
                return []
            }
            let subscriptions = try JSONDecoder().decode([BitkitSubscription].self, from: data)
            subscriptionsCache = subscriptions
            return subscriptions
        } catch {
            Logger.error("Failed to load subscriptions: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func getSubscription(id: String) -> BitkitSubscription? {
        return listSubscriptions().first { $0.id == id }
    }
    
    public func saveSubscription(_ subscription: BitkitSubscription) throws {
        var subscriptions = listSubscriptions()
        
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
        
        try persistSubscriptions(subscriptions)
    }
    
    public func deleteSubscription(id: String) throws {
        var subscriptions = listSubscriptions()
        subscriptions.removeAll { $0.id == id }
        try persistSubscriptions(subscriptions)
    }
    
    public func toggleActive(id: String) throws {
        var subscriptions = listSubscriptions()
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].isActive.toggle()
        try persistSubscriptions(subscriptions)
    }
    
    public func recordPayment(subscriptionId: String) throws {
        try recordPayment(subscriptionId: subscriptionId, paymentHash: nil, preimage: nil, feeSats: nil)
    }
    
    public func recordPayment(
        subscriptionId: String,
        paymentHash: String?,
        preimage: String?,
        feeSats: UInt64?
    ) throws {
        var subscriptions = listSubscriptions()
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionId }) else { return }
        
        let subscription = subscriptions[index]
        subscriptions[index].recordPayment(paymentHash: paymentHash, preimage: preimage, feeSats: feeSats)
        
        // Also record to payment history
        let payment = SubscriptionPayment(
            subscriptionId: subscriptionId,
            subscriptionName: subscription.providerName,
            amountSats: Int64(subscription.amountSats),
            status: .completed,
            preimage: preimage
        )
        try savePayment(payment)
        
        try persistSubscriptions(subscriptions)
    }
    
    public func activeSubscriptions() -> [BitkitSubscription] {
        listSubscriptions().filter { $0.isActive }
    }
    
    // MARK: - Proposals CRUD
    
    public func listProposals() -> [SubscriptionProposal] {
        if let cached = proposalsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: proposalsKey) else {
                return []
            }
            let proposals = try JSONDecoder().decode([SubscriptionProposal].self, from: data)
            proposalsCache = proposals
            return proposals
        } catch {
            Logger.error("Failed to load proposals: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func saveProposal(_ proposal: SubscriptionProposal) throws {
        var proposals = listProposals()
        
        if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
            proposals[index] = proposal
        } else {
            proposals.append(proposal)
        }
        
        try persistProposals(proposals)
    }
    
    public func deleteProposal(id: String) throws {
        var proposals = listProposals()
        proposals.removeAll { $0.id == id }
        try persistProposals(proposals)
    }
    
    // MARK: - Payment History CRUD
    
    public func listPayments() -> [SubscriptionPayment] {
        if let cached = paymentsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: paymentsKey) else {
                return []
            }
            let payments = try JSONDecoder().decode([SubscriptionPayment].self, from: data)
            paymentsCache = payments
            return payments.sorted { $0.paidAt > $1.paidAt }
        } catch {
            Logger.error("Failed to load payments: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func savePayment(_ payment: SubscriptionPayment) throws {
        var payments = listPayments()
        payments.append(payment)
        try persistPayments(payments)
    }
    
    public func getPayments(forSubscription subscriptionId: String) -> [SubscriptionPayment] {
        listPayments().filter { $0.subscriptionId == subscriptionId }
    }
    
    // MARK: - Clear All
    
    public func clearAll() throws {
        try persistSubscriptions([])
        try persistProposals([])
        try persistPayments([])
    }
    
    // MARK: - Private Persistence
    
    private func persistSubscriptions(_ subscriptions: [BitkitSubscription]) throws {
        let data = try JSONEncoder().encode(subscriptions)
        try keychain.store(key: subscriptionsKey, data: data)
        subscriptionsCache = subscriptions
    }
    
    private func persistProposals(_ proposals: [SubscriptionProposal]) throws {
        let data = try JSONEncoder().encode(proposals)
        try keychain.store(key: proposalsKey, data: data)
        proposalsCache = proposals
    }
    
    private func persistPayments(_ payments: [SubscriptionPayment]) throws {
        let data = try JSONEncoder().encode(payments)
        try keychain.store(key: paymentsKey, data: data)
        paymentsCache = payments
    }
}
