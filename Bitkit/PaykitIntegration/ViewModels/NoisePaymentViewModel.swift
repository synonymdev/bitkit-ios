//
//  NoisePaymentViewModel.swift
//  Bitkit
//
//  ViewModel for Noise payment flows with real Pubky-ring integration
//

import Foundation
import SwiftUI

@MainActor
class NoisePaymentViewModel: ObservableObject {
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isListening = false
    @Published var isSessionActive = false
    @Published var hasNoiseKey = false
    @Published var currentUserPubkey: String?
    @Published var paymentRequest: NoisePaymentRequest?
    @Published var paymentResponse: NoisePaymentResponse?
    @Published var errorMessage: String?
    
    private let noisePaymentService = NoisePaymentService.shared
    private let pubkyRingBridge = PubkyRingBridge.shared
    
    var noiseKeyStatus: String {
        hasNoiseKey ? "Active" : "Not configured"
    }
    
    var activeChannelsStatus: String {
        isConnected ? "1 active" : "None"
    }
    
    func checkSessionStatus() {
        if let session = pubkyRingBridge.getCachedSession() {
            isSessionActive = true
            currentUserPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32()
            hasNoiseKey = PaykitKeyManager.shared.noiseKeypairExists
        } else {
            isSessionActive = false
            currentUserPubkey = nil
            hasNoiseKey = false
        }
    }
    
    func refreshSession() {
        checkSessionStatus()
    }
    
    func handleSessionAuthenticated(_ session: PubkySession) {
        pubkyRingBridge.setCachedSession(session)
        checkSessionStatus()
    }
    
    func isValidRecipient(_ pubkey: String) -> Bool {
        // z-base32 pubkeys are 52 characters
        let trimmed = pubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 52 && trimmed.allSatisfy { c in
            "ybndrfg8ejkmcpqxot1uwisza345h769".contains(c.lowercased())
        }
    }
    
    func sendPayment(_ request: NoisePaymentRequest) async {
        isConnecting = true
        errorMessage = nil
        
        do {
            let response = try await noisePaymentService.sendPaymentRequest(request)
            paymentResponse = response
            isConnected = true
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    func receivePayment() async {
        guard isSessionActive else {
            errorMessage = "Please authenticate with Pubky-ring first"
            return
        }
        
        isListening = true
        isConnecting = true
        errorMessage = nil
        
        do {
            if let request = try await noisePaymentService.receivePaymentRequest() {
                paymentRequest = request
                isConnected = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    func stopListening() {
        isListening = false
        noisePaymentService.stopListening()
    }
    
    func acceptIncomingRequest() async {
        guard let request = paymentRequest else { return }
        
        do {
            try await noisePaymentService.acceptPaymentRequest(request)
            paymentRequest = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func declineIncomingRequest() async {
        guard let request = paymentRequest else { return }
        
        do {
            try await noisePaymentService.declinePaymentRequest(request)
            paymentRequest = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

