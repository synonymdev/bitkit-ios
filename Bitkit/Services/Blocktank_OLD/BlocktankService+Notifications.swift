//
//  BlocktankService+Notifications.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import Foundation

extension BlocktankService_OLD {
    // TODO: token is cached above so occasionally check the status of the device with Blocktank. If not registered but we have a token then retry registration.
    
    func selfTest() async throws {
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") else {
            throw BlocktankError_deprecated.missingDeviceToken
        }
        
        Logger.debug("Sending test notification to self")
        
        let params = [
            "data": [
                "source": "blocktank",
                "type": BlocktankNotificationType.orderPaymentConfirmed.rawValue,
                "payload": ["secretMessage": "hello"]
            ]
        ] as [String: Any]
                
        let result = try await postRequest(Env.blocktankPushNotificationServer + "/device/\(deviceToken)/test-notification", params)
        Logger.info("Notification sent to self: \(String(data: result, encoding: .utf8) ?? "")")
    }
}
