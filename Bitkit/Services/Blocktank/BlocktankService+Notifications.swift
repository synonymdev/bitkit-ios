//
//  BlocktankService+Notifications.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import Foundation

extension BlocktankService {
    func registerDevice(deviceToken: String) async throws {
        UserDefaults.standard.setValue(deviceToken, forKey: "deviceToken") // Token cached so we can retry registration if there are any issues
        
        guard let nodeId = LightningService.shared.nodeId else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        Logger.debug("Registering device for notifications")
                
        let isoTimestamp = ISO8601DateFormatter().string(from: Date())
        let messageToSign = "bitkit-notifications\(deviceToken)\(isoTimestamp)"
        
        let signature = try await LightningService.shared.sign(message: messageToSign)
        
        let keypair = try Crypto.generateKeyPair()
        
        Logger.debug("Notification encryption public key: \(keypair.publicKey.hex)")
        
        // New keypair for each token registration
        if try Keychain.exists(key: .pushNotificationPrivateKey) {
            try? Keychain.delete(key: .pushNotificationPrivateKey)
        }
        
        try Keychain.save(key: .pushNotificationPrivateKey, data: keypair.privateKey)
        
        let params = [
            "deviceToken": deviceToken,
            "publicKey": keypair.publicKey.hex,
            "features": Env.pushNotificationFeatures.map { $0.feature },
            "nodeId": nodeId,
            "isoTimestamp": isoTimestamp,
            "signature": signature
        ] as [String: Any]
        
        let result = try await postRequest(Env.blocktankPushNotificationServer + "/device", params)
        Logger.info("Device registered: \(String(data: result, encoding: .utf8) ?? "")")
    }
    
    // TODO: token is cached above so occasionally check the status of the device with Blocktank. If not registered but we have a token then retry registration.
    
    func selfTest() async throws {
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") else {
            throw BlocktankError.missingDeviceToken
        }
        
        Logger.debug("Sending test notification to self")
        
        let params = [
            "data": [
                "source": "blocktank",
                "type": "incomingHtlc",
                "payload": ["secretMessage": "hello"]
            ]
        ] as [String: Any]
                
        let result = try await postRequest(Env.blocktankPushNotificationServer + "/device/\(deviceToken)/test-notification", params)
        Logger.info("Notification sent to self: \(String(data: result, encoding: .utf8) ?? "")")
    }
}
