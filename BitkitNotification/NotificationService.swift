//
//  NotificationService.swift
//  BitkitNotification
//
//  Created by Jason van den Berg on 2024/07/03.
//

import LDKNode
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    let walletIndex = 0 // Assume first wallet for now
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        
        Task {
            do {
                try await LightningService.shared.setup(walletIndex: self.walletIndex) // Assume first wallet for now
                
                try await LightningService.shared.start { event in
                    self.handleLdkEvent(event: event)
                }
            } catch {
                self.bestAttemptContent?.title = "Lightning error"
                self.bestAttemptContent?.body = error.localizedDescription
                
                Logger.error(error, context: "failed to setup node in notification service")
                self.dumpLdkLogs()
                await self.deliver()
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
        case .channelPending(channelId: let channelId, userChannelId: let userChannelId, formerTemporaryChannelId: let formerTemporaryChannelId, counterpartyNodeId: let counterpartyNodeId, fundingTxo: let fundingTxo):
            self.bestAttemptContent?.title = "Channel Opened"
            self.bestAttemptContent?.body = "Pending"
        // Don't deliver, give a chance for channelReady event to update the content
        case .channelReady(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId):
            self.bestAttemptContent?.title = "Channel ready"
            self.bestAttemptContent?.body = "Usable"
            Task {
                await self.deliver()
            }
        case .channelClosed(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId, reason: let reason):
            self.bestAttemptContent?.title = "Channel closed"
            self.bestAttemptContent?.body = reason.debugDescription // TODO: Reason string
            Task {
                await self.deliver()
            }
        case .paymentSuccessful:
            break
        case .paymentFailed:
            break
        case .paymentClaimable:
            break
        }
    }
    
    func deliver() async {
        try? await LightningService.shared.stop()
        
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            // TODO: Stop LDK
            
            contentHandler(bestAttemptContent)
        }
    }
    
    func dumpLdkLogs() {
        let dir = Env.ldkStorage(walletIndex: self.walletIndex)
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")
        
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            print("*****LDK-NODE LOG******")
            for line in lines.suffix(20) {
                print(line)
            }
        } catch {
            Logger.error(error, context: "failed to load ldk log file")
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
