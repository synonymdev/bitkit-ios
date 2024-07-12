//
//  NotificationService.swift
//  BitkitNotification
//
//  Created by Jason van den Berg on 2024/07/03.
//

import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        
        Task {
            do {
                let mnemonic = "science fatigue phone inner pipe solve acquire nothing birth slow armor flip debate gorilla select settle talk badge uphold firm video vibrant banner casual" // = generateEntropyMnemonic()
                let passphrase: String? = nil
                
                print("Setting up LDK")
                try LightningService.shared.setup(mnemonic: mnemonic, passphrase: passphrase)
                
                print("Starting LDK")
                
                bestAttemptContent?.title = "Lightning setup"

                try await LightningService.shared.start()

                bestAttemptContent?.title = "Lightning started"

                bestAttemptContent?.body = LightningService.shared.nodeId ?? "ERROR NO NODE ID"
                
                print("Done")
            } catch {
                bestAttemptContent?.title = "Lightning error"
                bestAttemptContent?.body = error.localizedDescription
            }
            
            deliver()
        }
    }
    
    func deliver() {
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            //TODO: Stop LDK
            
            contentHandler(bestAttemptContent)
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
