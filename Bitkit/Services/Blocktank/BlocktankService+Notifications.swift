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
        
        let publicKey = "03864ef025fde8fb587d989186ce6a4a186895ee44a926bfc370e2c366597a3f8f"
        // TODO: use real public key like below to enable decryption of the push notification payload so we know which node event to wait for
        // https://github.com/SeverinAlexB/ln-verifymessagejs/blob/master/src/shared_secret.ts
        
        let params = [
            "deviceToken": deviceToken,
            "publicKey": publicKey,
            "features": Env.pushNotificationFeatures,
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
                
        let result = try await postRequest("notifications/api/device/\(deviceToken)/test-notification", params)
        Logger.info("Notification sent to self: \(String(data: result, encoding: .utf8) ?? "")")
    }
}
