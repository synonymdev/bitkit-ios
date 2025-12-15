//
//  AutoPayViewModel.swift
//  Bitkit
//
//  ViewModel for Auto-Pay settings
//

import Foundation
import SwiftUI

@MainActor
class AutoPayViewModel: ObservableObject {
    @Published var settings: AutoPaySettings
    @Published var peerLimits: [StoredPeerLimit] = []
    @Published var rules: [StoredAutoPayRule] = []
    @Published var isLoading = false
    
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
        isLoading = false
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
    
    /// Evaluate if a payment should be auto-approved
    /// Implements AutopayEvaluator protocol for PaymentRequestService
    func evaluate(peerPubkey: String, amount: Int64, methodId: String) -> AutopayEvaluationResult {
        // Check if autopay is enabled
        guard settings.isEnabled else {
            return .denied(reason: "Auto-pay is disabled")
        }
        
        // Check global daily limit
        if amount > settings.globalDailyLimit {
            return .denied(reason: "Would exceed daily limit")
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
}

