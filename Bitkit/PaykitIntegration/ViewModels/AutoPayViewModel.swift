//
//  AutoPayViewModel.swift
//  Bitkit
//
//  ViewModel for Auto-Pay settings with notification preferences and confirmation toggles
//

import Foundation
import SwiftUI

@MainActor
class AutoPayViewModel: ObservableObject {
    @Published var settings: AutoPaySettings
    @Published var peerLimits: [StoredPeerLimit] = []
    @Published var rules: [StoredAutoPayRule] = []
    @Published var history: [AutoPayHistoryEntry] = []
    @Published var isLoading = false
    
    // Computed spending amounts
    @Published var spentToday: Int64 = 0
    
    private let autoPayStorage: AutoPayStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.autoPayStorage = AutoPayStorage(identityName: identityName)
        self.settings = autoPayStorage.getSettings()
    }
    
    func loadSettings() {
        isLoading = true
        settings = autoPayStorage.getSettings()
        peerLimits = autoPayStorage.getPeerLimits()
        rules = autoPayStorage.getRules()
        calculateSpentToday()
        isLoading = false
    }
    
    func loadHistory() {
        history = autoPayStorage.getHistory()
    }
    
    private func calculateSpentToday() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        
        spentToday = history
            .filter { $0.timestamp >= startOfDay && $0.wasApproved }
            .reduce(0) { $0 + $1.amount }
    }
    
    func saveSettings() throws {
        try autoPayStorage.saveSettings(settings)
    }
    
    func addPeerLimit(_ limit: StoredPeerLimit) throws {
        try autoPayStorage.savePeerLimit(limit)
        loadSettings()
    }
    
    func deletePeerLimit(_ limit: StoredPeerLimit) throws {
        try autoPayStorage.deletePeerLimit(id: limit.id)
        loadSettings()
    }
    
    func addRule(_ rule: StoredAutoPayRule) throws {
        try autoPayStorage.saveRule(rule)
        loadSettings()
    }
    
    func deleteRule(_ rule: StoredAutoPayRule) throws {
        try autoPayStorage.deleteRule(id: rule.id)
        loadSettings()
    }
    
    func recordPayment(peerPubkey: String, peerName: String, amount: Int64, approved: Bool, reason: String = "") {
        let entry = AutoPayHistoryEntry(
            peerPubkey: peerPubkey,
            peerName: peerName,
            amount: amount,
            wasApproved: approved,
            reason: reason
        )
        
        try? autoPayStorage.saveHistoryEntry(entry)
        loadHistory()
        calculateSpentToday()
    }
    
    /// Evaluate if a payment should be auto-approved
    /// Implements AutopayEvaluator protocol for PaymentRequestService
    func evaluate(peerPubkey: String, peerName: String, amount: Int64, methodId: String, isSubscription: Bool = false) -> AutopayEvaluationResult {
        // Check if autopay is enabled
        guard settings.isEnabled else {
            return .denied(reason: "Auto-pay is disabled")
        }
        
        // Check per-payment limit
        if amount > settings.maxPerPayment {
            if settings.confirmHighValue {
                return .needsApproval
            }
            return .denied(reason: "Exceeds max per payment")
        }
        
        // Check global daily limit
        if spentToday + amount > settings.globalDailyLimit {
            if settings.notifyOnLimitReached {
                sendLimitReachedNotification()
            }
            return .denied(reason: "Would exceed daily limit")
        }
        
        // Check if first payment to peer requires confirmation
        let isNewPeer = !peerLimits.contains { $0.peerPubkey == peerPubkey }
        if isNewPeer && settings.confirmFirstPayment {
            if settings.notifyOnNewPeer {
                sendNewPeerNotification(peerName: peerName)
            }
            return .needsApproval
        }
        
        // Check subscription confirmation requirement
        if isSubscription && settings.confirmSubscriptions {
            return .needsApproval
        }
        
        // Check biometric for large amounts
        if settings.biometricForLarge && amount > 100000 {
            return .needsBiometric
        }
        
        // Check peer-specific limit
        if let peerLimitIndex = peerLimits.firstIndex(where: { $0.peerPubkey == peerPubkey }) {
            var peerLimit = peerLimits[peerLimitIndex]
            peerLimit.resetIfNeeded()
            
            // Update if reset occurred
            if peerLimit.spentSats != peerLimits[peerLimitIndex].spentSats {
                peerLimits[peerLimitIndex] = peerLimit
                try? autoPayStorage.savePeerLimit(peerLimit)
            }
            
            if peerLimit.spentSats + amount > peerLimit.limitSats {
                return .denied(reason: "Would exceed peer limit")
            }
        }
        
        // Check auto-pay rules
        for rule in rules where rule.isEnabled {
            if rule.matches(amount: amount, method: methodId, peer: peerPubkey) {
                return .approved(ruleId: rule.id, ruleName: rule.name)
            }
        }
        
        return .needsApproval
    }
    
    // MARK: - Notifications
    
    private func sendLimitReachedNotification() {
        NotificationCenter.default.post(
            name: Notification.Name("PaykitAutoPayLimitReached"),
            object: nil
        )
    }
    
    private func sendNewPeerNotification(peerName: String) {
        NotificationCenter.default.post(
            name: Notification.Name("PaykitAutoPayNewPeer"),
            object: nil,
            userInfo: ["peerName": peerName]
        )
    }
}

// MARK: - History Entry Model

public struct AutoPayHistoryEntry: Identifiable, Codable {
    public let id: String
    let peerPubkey: String
    let peerName: String
    let amount: Int64
    let wasApproved: Bool
    let reason: String
    let timestamp: Date
    
    init(
        id: String = UUID().uuidString,
        peerPubkey: String,
        peerName: String,
        amount: Int64,
        wasApproved: Bool,
        reason: String = "",
        timestamp: Date = Date()
    ) {
        self.id = id
        self.peerPubkey = peerPubkey
        self.peerName = peerName
        self.amount = amount
        self.wasApproved = wasApproved
        self.reason = reason
        self.timestamp = timestamp
    }
}

