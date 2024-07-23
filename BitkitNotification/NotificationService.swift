//
//  NotificationService.swift
//  BitkitNotification
//
//  Created by Jason van den Berg on 2024/07/03.
//

import UserNotifications
import LDKNode

class NotificationService: UNNotificationServiceExtension {
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        
        Task {
            do {
                let mnemonic = "always coconut smooth scatter steel web version exist broken motion damage board trap dinosaur include alone dust flag paddle give divert journey garden bench" // = generateEntropyMnemonic()
                let passphrase: String? = nil
                
                try await LightningService.shared.setup(mnemonic: mnemonic, passphrase: passphrase)
                
                try await LightningService.shared.start { event in
                    self.handleLdkEvent(event: event)
                }
            } catch {
                bestAttemptContent?.title = "Lightning error"
                bestAttemptContent?.body = error.localizedDescription
                
                Logger.error(error, context: "failed to setup node in notification service")
                dumpLdkLogs()
                await deliver()
            }
        }
    }
    
    func handleLdkEvent(event: Event) {
        switch event {
        case .paymentReceived(paymentId: let paymentId, paymentHash: let paymentHash, amountMsat: let amountMsat):
            self.bestAttemptContent?.title = "Payment Received"
            self.bestAttemptContent?.body = "⚡ \(amountMsat / 1000)"
            Task {
                await self.deliver()
            }
            break
        case .channelPending(channelId: let channelId, userChannelId: let userChannelId, formerTemporaryChannelId: let formerTemporaryChannelId, counterpartyNodeId: let counterpartyNodeId, fundingTxo: let fundingTxo):
            self.bestAttemptContent?.title = "Channel Opened"
            self.bestAttemptContent?.body = "Pending"
            //Don't deliver, give a chance for channelReady event to update the content
            break
        case .channelReady(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId):
            self.bestAttemptContent?.title = "Channel ready"
            self.bestAttemptContent?.body = "Usable"
            Task {
                await self.deliver()
            }
            break
        case .channelClosed(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId, reason: let reason):
            self.bestAttemptContent?.title = "Channel closed"
            self.bestAttemptContent?.body = reason.debugDescription //TODO: Reason string
            Task {
                await self.deliver()
            }
            break
        case .paymentSuccessful(_, _, _):
            break
        case .paymentFailed(_, _, _):
            break
        case .paymentClaimable(_, _, _, _):
            break
        }
    }
    
    func deliver() async {
        try? await LightningService.shared.stop()
        
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            //TODO: Stop LDK
            
            contentHandler(bestAttemptContent)
        }
    }
    
    func dumpLdkLogs() {
        let dir = Env.ldkStorage
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")
        
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            print("*****LDK-NODE LOG******")
            lines.suffix(20).forEach { line in
                print(line)
            }
        } catch {
            Logger.error(error, context: "failed to load ldk log file")
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
