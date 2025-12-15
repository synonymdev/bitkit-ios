//
//  NoisePaymentViewModel.swift
//  Bitkit
//
//  ViewModel for Noise payment flows
//

import Foundation
import SwiftUI

@MainActor
class NoisePaymentViewModel: ObservableObject {
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var paymentRequest: NoisePaymentRequest?
    @Published var paymentResponse: NoisePaymentResponse?
    @Published var errorMessage: String?
    
    private let noisePaymentService = NoisePaymentService.shared
    
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
}

