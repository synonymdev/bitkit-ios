//
//  PipBackgroundHandler.swift
//  Bitkit iOS - PIP Background Webhook Processing
//
//  Handles silent APNs notifications for webhook delivery
//

import Foundation
import UserNotifications
import PipUniFFI

class PipBackgroundHandler: NSObject, UNUserNotificationCenterDelegate {
    
    static let shared = PipBackgroundHandler()
    private var sessionStore: PipSessionStore?
    private var config: PipConfig?
    
    private override init() {
        super.init()
    }
    
    // MARK: - Initialization
    
    func initialize(config: PipConfig) {
        self.config = config
        self.sessionStore = PipSessionStore(config: config)
        UNUserNotificationCenter.current().delegate = self
    }
    
    // MARK: - Silent Push Handling
    
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        
        guard let quoteId = userInfo["quote_id"] as? String else {
            print("[PIP] No quote_id in notification payload")
            completionHandler(.failed)
            return
        }
        
        print("[PIP] Received silent push for quote: \(quoteId)")
        
        Task {
            do {
                // Load session data from storage
                guard let sessionData = await sessionStore?.loadSessionData(quoteId: quoteId) else {
                    print("[PIP] No session found for quote: \(quoteId)")
                    completionHandler(.noData)
                    return
                }
                
                print("[PIP] Fetching webhook from receiver...")
                
                // Fetch webhook from receiver
                let webhookData = try await fetchWebhook(
                    quoteId: quoteId,
                    receiverUrl: sessionData.receiverUrl
                )
                
                print("[PIP] Webhook fetched, processing...")
                
                // Reconstruct session handle (for v1.0, we use stored session reference)
                guard let session = await sessionStore?.getSessionHandle(quoteId: quoteId) else {
                    print("[PIP] Cannot reconstruct session handle")
                    completionHandler(.failed)
                    return
                }
                
                // Get HMAC key from config
                guard let hmacKey = self.config?.webhookHmacKey else {
                    print("[PIP] No HMAC key in config")
                    completionHandler(.failed)
                    return
                }
                
                // Process webhook via Rust SDK
                let success = try processWebhook(
                    session,
                    webhookJson: webhookData.json,
                    hmacSig: webhookData.hmacSig,
                    schnorrSig: webhookData.schnorrSig,
                    hmacKey: hmacKey
                )
                
                if success {
                    print("[PIP] Webhook processed successfully")
                    
                    // Update stored session status
                    let newStatus = session.status()
                    await sessionStore?.updateStatus(quoteId: quoteId, status: newStatus)
                    
                    // Broadcast notification to app
                    NotificationCenter.default.post(
                        name: .pipWebhookProcessed,
                        object: nil,
                        userInfo: [
                            "quote_id": quoteId,
                            "status": self.statusToString(newStatus)
                        ]
                    )
                    
                    completionHandler(.newData)
                } else {
                    print("[PIP] Webhook processing failed")
                    completionHandler(.failed)
                }
                
            } catch {
                print("[PIP] Error processing webhook: \(error)")
                completionHandler(.failed)
            }
        }
    }
    
    // MARK: - Webhook Fetching
    
    private func fetchWebhook(quoteId: String, receiverUrl: String) async throws -> WebhookData {
        let urlString = "\(receiverUrl)/pip/quote/\(quoteId)"
        
        guard let url = URL(string: urlString) else {
            throw PipError.NetworkError
        }
        
        print("[PIP] Fetching webhook from: \(urlString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PipError.NetworkError
        }
        
        print("[PIP] Webhook response status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            throw PipError.NetworkError
        }
        
        // Extract HMAC and Schnorr signatures from headers
        let hmacSig = httpResponse.value(forHTTPHeaderField: "X-PIP-HMAC") ?? ""
        let schnorrSig = httpResponse.value(forHTTPHeaderField: "X-PIP-Schnorr") ?? ""
        
        guard !hmacSig.isEmpty && !schnorrSig.isEmpty else {
            print("[PIP] Missing signature headers")
            throw PipError.Invalid
        }
        
        print("[PIP] Got webhook with signatures - HMAC: \(hmacSig.prefix(16))..., Schnorr: \(schnorrSig.prefix(16))...")
        
        return WebhookData(
            json: [UInt8](data),
            hmacSig: hmacSig,
            schnorrSig: schnorrSig
        )
    }
    
    // MARK: - Helper Methods
    
    private func statusToString(_ status: PipStatus) -> String {
        switch status {
        case .quoted:
            return "Quoted"
        case .invoicePresented:
            return "InvoicePresented"
        case .waitingPreimage:
            return "WaitingPreimage"
        case .preimageReceived:
            return "PreimageReceived"
        case .broadcasted:
            return "Broadcasted"
        case .confirmed:
            return "Confirmed"
        case .swept:
            return "Swept"
        case .failed:
            return "Failed"
        }
    }
}

// MARK: - Supporting Types

struct WebhookData {
    let json: [UInt8]
    let hmacSig: String
    let schnorrSig: String
}

extension Notification.Name {
    static let pipWebhookProcessed = Notification.Name("pipWebhookProcessed")
}
