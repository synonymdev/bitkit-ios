//
//  PipSessionStore.swift
//  Bitkit iOS - PIP Session Persistence
//
//  Manages session data storage in UserDefaults and Keychain
//

import Foundation
import Security
import PipUniFFI

class PipSessionStore {
    
    let config: PipConfig
    private let userDefaults = UserDefaults.standard
    private let keychainService = "to.bitkit.pip"
    
    // In-memory session handle cache
    private var sessionHandles: [String: Arc<PipSessionHandle>] = [:]
    private let lock = NSLock()
    
    init(config: PipConfig) {
        self.config = config
    }
    
    // MARK: - Session Handle Management
    
    func storeSessionHandle(quoteId: String, session: Arc<PipSessionHandle>) {
        lock.lock()
        defer { lock.unlock() }
        sessionHandles[quoteId] = session
    }
    
    func getSessionHandle(quoteId: String) -> Arc<PipSessionHandle>? {
        lock.lock()
        defer { lock.unlock() }
        return sessionHandles[quoteId]
    }
    
    func removeSessionHandle(quoteId: String) {
        lock.lock()
        defer { lock.unlock() }
        sessionHandles.removeValue(forKey: quoteId)
    }
    
    // MARK: - Session Data Persistence
    
    func saveSessionData(
        quoteId: String,
        session: Arc<PipSessionHandle>,
        receiverUrl: String
    ) async {
        let sessionData: [String: Any] = [
            "quote_id": quoteId,
            "invoice": session.invoiceBolt11(),
            "payment_hash": session.paymentHashHex(),
            "receiver_url": receiverUrl,
            "status": statusToString(session.status()),
            "created_at": Date().timeIntervalSince1970,
            "updated_at": Date().timeIntervalSince1970
        ]
        
        let key = sessionKey(quoteId: quoteId)
        userDefaults.set(sessionData, forKey: key)
        userDefaults.synchronize()
        
        // Also store in memory
        storeSessionHandle(quoteId: quoteId, session: session)
        
        print("[PIP Store] Saved session data for \(quoteId)")
    }
    
    func loadSessionData(quoteId: String) async -> SessionData? {
        let key = sessionKey(quoteId: quoteId)
        
        guard let dict = userDefaults.dictionary(forKey: key),
              let invoice = dict["invoice"] as? String,
              let paymentHash = dict["payment_hash"] as? String,
              let receiverUrl = dict["receiver_url"] as? String,
              let status = dict["status"] as? String else {
            print("[PIP Store] No session data found for \(quoteId)")
            return nil
        }
        
        print("[PIP Store] Loaded session data for \(quoteId)")
        
        return SessionData(
            quoteId: quoteId,
            invoice: invoice,
            paymentHash: paymentHash,
            receiverUrl: receiverUrl,
            status: status
        )
    }
    
    func updateStatus(quoteId: String, status: PipStatus) async {
        let key = sessionKey(quoteId: quoteId)
        
        guard var sessionData = userDefaults.dictionary(forKey: key) else {
            print("[PIP Store] Cannot update status - no session data for \(quoteId)")
            return
        }
        
        sessionData["status"] = statusToString(status)
        sessionData["updated_at"] = Date().timeIntervalSince1970
        
        // Extract txid if available
        if let txid = extractTxid(from: status) {
            sessionData["txid"] = txid
        }
        
        userDefaults.set(sessionData, forKey: key)
        userDefaults.synchronize()
        
        print("[PIP Store] Updated status for \(quoteId): \(statusToString(status))")
    }
    
    func deleteSession(quoteId: String) {
        let key = sessionKey(quoteId: quoteId)
        userDefaults.removeObject(forKey: key)
        userDefaults.synchronize()
        
        removeSessionHandle(quoteId: quoteId)
        
        print("[PIP Store] Deleted session \(quoteId)")
    }
    
    func getAllSessions() -> [SessionData] {
        var sessions: [SessionData] = []
        
        let allKeys = userDefaults.dictionaryRepresentation().keys
        let sessionKeys = allKeys.filter { $0.hasPrefix("pip_session_") }
        
        for key in sessionKeys {
            if let dict = userDefaults.dictionary(forKey: key),
               let quoteId = dict["quote_id"] as? String,
               let invoice = dict["invoice"] as? String,
               let paymentHash = dict["payment_hash"] as? String,
               let receiverUrl = dict["receiver_url"] as? String,
               let status = dict["status"] as? String {
                
                sessions.append(SessionData(
                    quoteId: quoteId,
                    invoice: invoice,
                    paymentHash: paymentHash,
                    receiverUrl: receiverUrl,
                    status: status
                ))
            }
        }
        
        return sessions
    }
    
    // MARK: - Keychain (for HMAC key)
    
    func saveHmacKey(_ key: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "webhook_hmac_key",
            kSecValueData as String: key
        ]
        
        // Delete existing
        SecItemDelete(query as CFDictionary)
        
        // Add new
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecSuccess {
            print("[PIP Store] HMAC key saved to Keychain")
            return true
        } else {
            print("[PIP Store] Failed to save HMAC key: \(status)")
            return false
        }
    }
    
    func loadHmacKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "webhook_hmac_key",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data else {
            print("[PIP Store] No HMAC key found in Keychain")
            return nil
        }
        
        print("[PIP Store] HMAC key loaded from Keychain")
        return data
    }
    
    func generateAndSaveHmacKey() -> Data {
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        
        guard result == errSecSuccess else {
            fatalError("Failed to generate random HMAC key")
        }
        
        _ = saveHmacKey(keyData)
        
        print("[PIP Store] Generated new HMAC key")
        return keyData
    }
    
    // MARK: - Helper Methods
    
    private func sessionKey(quoteId: String) -> String {
        return "pip_session_\(quoteId)"
    }
    
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
    
    private func extractTxid(from status: PipStatus) -> String? {
        switch status {
        case .broadcasted(let txid), .swept(let txid):
            return txid
        default:
            return nil
        }
    }
}

// MARK: - Supporting Types

struct SessionData {
    let quoteId: String
    let invoice: String
    let paymentHash: String
    let receiverUrl: String
    let status: String
}
