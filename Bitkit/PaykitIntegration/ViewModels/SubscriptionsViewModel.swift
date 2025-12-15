//
//  SubscriptionsViewModel.swift
//  Bitkit
//
//  ViewModel for Subscriptions management
//

import Foundation
import SwiftUI

@MainActor
class SubscriptionsViewModel: ObservableObject {
    @Published var subscriptions: [Subscription] = []
    @Published var isLoading = false
    @Published var showingAddSubscription = false
    
    private let subscriptionStorage: SubscriptionStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.subscriptionStorage = SubscriptionStorage(identityName: identityName)
    }
    
    func loadSubscriptions() {
        isLoading = true
        subscriptions = subscriptionStorage.listSubscriptions()
        isLoading = false
    }
    
    func addSubscription(_ subscription: Subscription) throws {
        try subscriptionStorage.saveSubscription(subscription)
        loadSubscriptions()
    }
    
    func updateSubscription(_ subscription: Subscription) throws {
        try subscriptionStorage.saveSubscription(subscription)
        loadSubscriptions()
    }
    
    func deleteSubscription(_ subscription: Subscription) throws {
        try subscriptionStorage.deleteSubscription(id: subscription.id)
        loadSubscriptions()
    }
    
    func toggleActive(_ subscription: Subscription) throws {
        try subscriptionStorage.toggleActive(id: subscription.id)
        loadSubscriptions()
    }
    
    func recordPayment(_ subscription: Subscription) throws {
        try subscriptionStorage.recordPayment(subscriptionId: subscription.id)
        loadSubscriptions()
    }
    
    var activeSubscriptions: [Subscription] {
        subscriptionStorage.activeSubscriptions()
    }
}

