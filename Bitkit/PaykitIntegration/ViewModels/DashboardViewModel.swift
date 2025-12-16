//
//  DashboardViewModel.swift
//  Bitkit
//
//  ViewModel for Paykit Dashboard
//

import Foundation
import SwiftUI

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var recentReceipts: [PaymentReceipt] = []
    @Published var contactCount: Int = 0
    @Published var totalSent: UInt64 = 0
    @Published var totalReceived: UInt64 = 0
    @Published var pendingCount: Int = 0
    @Published var isLoading = true
    
    @Published var hasPaymentMethods: Bool = false
    @Published var hasPublishedMethods: Bool = false
    @Published var autoPayEnabled: Bool = false
    @Published var activeSubscriptions: Int = 0
    @Published var pendingRequests: Int = 0
    @Published var publishedMethodsCount: Int = 0
    @Published var sessionCount: Int = 0
    
    private let receiptStorage: ReceiptStorage
    private let contactStorage: ContactStorage
    private let autoPayStorage: AutoPayStorage
    private let subscriptionStorage: SubscriptionStorage
    private let paymentRequestStorage: PaymentRequestStorage
    
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.receiptStorage = ReceiptStorage(identityName: identityName)
        self.contactStorage = ContactStorage(identityName: identityName)
        self.autoPayStorage = AutoPayStorage(identityName: identityName)
        self.subscriptionStorage = SubscriptionStorage(identityName: identityName)
        self.paymentRequestStorage = PaymentRequestStorage(identityName: identityName)
    }
    
    func loadDashboard() {
        isLoading = true
        
        // Load recent receipts
        recentReceipts = receiptStorage.recentReceipts(limit: 5)
        
        // Load stats
        contactCount = contactStorage.listContacts().count
        totalSent = receiptStorage.totalSent()
        totalReceived = receiptStorage.totalReceived()
        pendingCount = receiptStorage.pendingCount()
        
        // Load Auto-Pay status
        let autoPaySettings = autoPayStorage.getSettings()
        autoPayEnabled = autoPaySettings.isEnabled
        
        // Load Subscriptions count
        activeSubscriptions = subscriptionStorage.activeSubscriptions().count
        
        // Load Payment Requests count
        pendingRequests = paymentRequestStorage.pendingCount()
        
        // Load Session count
        sessionCount = PubkyRingBridge.shared.getAllSessions().count
        
        isLoading = false
    }
    
    var isSetupComplete: Bool {
        contactCount > 0 && hasPaymentMethods && hasPublishedMethods
    }
    
    var setupProgress: Int {
        var completed = 1 // Identity is always created at this point
        if contactCount > 0 { completed += 1 }
        if hasPaymentMethods { completed += 1 }
        if hasPublishedMethods { completed += 1 }
        return (completed * 100) / 4
    }
}

