//
//  SubscriptionStorage.swift
//  Bitkit
//
//  Persistent storage for subscriptions using Keychain.
//

import Foundation

/// Manages persistent storage of subscriptions
public class SubscriptionStorage {
    
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    // In-memory cache
    private var subscriptionsCache: [Subscription]?
    
    private var storageKey: String {
        "paykit.subscriptions.\(identityName)"
    }
    
    public init(identityName: String = "default", keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    // MARK: - CRUD Operations
    
    public func listSubscriptions() -> [Subscription] {
        if let cached = subscriptionsCache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: storageKey) else {
                return []
            }
            let subscriptions = try JSONDecoder().decode([Subscription].self, from: data)
            subscriptionsCache = subscriptions
            return subscriptions
        } catch {
            Logger.error("SubscriptionStorage: Failed to load subscriptions: \(error)", context: "SubscriptionStorage")
            return []
        }
    }
    
    public func getSubscription(id: String) -> Subscription? {
        return listSubscriptions().first { $0.id == id }
    }
    
    public func saveSubscription(_ subscription: Subscription) throws {
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
        var subscriptions = listSubscriptions()
        guard let index = subscriptions.firstIndex(where: { $0.id == subscriptionId }) else { return }
        subscriptions[index].recordPayment()
        try persistSubscriptions(subscriptions)
    }
    
    public func activeSubscriptions() -> [Subscription] {
        listSubscriptions().filter { $0.isActive }
    }
    
    public func clearAll() throws {
        try persistSubscriptions([])
    }
    
    // MARK: - Private
    
    private func persistSubscriptions(_ subscriptions: [Subscription]) throws {
        let data = try JSONEncoder().encode(subscriptions)
        try keychain.store(key: storageKey, data: data)
        subscriptionsCache = subscriptions
    }
}

