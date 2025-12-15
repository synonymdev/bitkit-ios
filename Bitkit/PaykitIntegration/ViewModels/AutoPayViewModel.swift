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
}

