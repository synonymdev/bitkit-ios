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
    
    var receieveTime: CFAbsoluteTime?
    var nodeStartedTime: CFAbsoluteTime?
    var lightningEventTime: CFAbsoluteTime?
    var nodeStopTime: CFAbsoluteTime?
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.receieveTime = CFAbsoluteTimeGetCurrent()
        
        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        
        Task {
            do {
                Logger.debug("Received notification")
                do {
                    try await self.decryptPayload(request)
                } catch {
                    Logger.error(error, context: "failed to decrypt payload")
                }
                
                try await LightningService.shared.setup(walletIndex: self.walletIndex) // Assume first wallet for now

                try await LightningService.shared.start { event in
                    self.lightningEventTime = CFAbsoluteTimeGetCurrent()
                    self.handleLdkEvent(event: event)
                }

                self.nodeStartedTime = CFAbsoluteTimeGetCurrent()
                
            } catch {
                self.bestAttemptContent?.title = "Lightning error"
                self.bestAttemptContent?.body = error.localizedDescription
                
                Logger.error(error, context: "failed to setup node in notification service")
                self.dumpLdkLogs()
                await self.deliver()
            }
        }
    }
    
    func decryptPayload(_ request: UNNotificationRequest) async throws {
        guard let aps = request.content.userInfo["aps"] as? AnyObject else {
            Logger.error("Missing aps payload")
            return
        }
        
        guard
            let alert = aps["alert"] as? AnyObject,
            let payload = alert["payload"] as? AnyObject,
            let cipher = payload["cipher"] as? String,
            let iv = payload["iv"] as? String,
            let publicKey = payload["publicKey"] as? String,
            let tag = payload["tag"] as? String
        else {
            Logger.error("Missing payload details")
            return
        }
        
        guard let ciphertext = Data(base64Encoded: cipher) else {
            Logger.error("Failed to decode cipher")
            return
        }
                
        guard let privateKey = try Keychain.load(key: .pushNotificationPrivateKey) else {
            Logger.error("Missing pushNotificationPrivateKey")
            return
        }
        
        let password = try Crypto.generateSharedSecret(privateKey: privateKey, nodePubkey: publicKey, derivationName: "bitkit-notifications")

        let decrypted = try Crypto.decrypt(
            .init(cipher: ciphertext, iv: iv.hexaData, tag: tag.hexaData),
            secretKey: password
        )
        
        Logger.debug("Decrypted payload: \(String(data: decrypted, encoding: .utf8) ?? "")")

        // Optional("{\"source\":\"blocktank\",\"type\":\"incomingHtlc\",\"payload\":{\"secretMessage\":\"hello\"},\"createdAt\":\"2024-09-13T17:35:56.766Z\"}") [NotificationService.swift: decryptPayload(_:)
        
        // {"source":"blocktank","type":"orderPaymentConfirmed","payload":{"lspId":"03b9a456fb45d5ac98c02040d39aec77fa3eeb41fd22cf40b862b393bcfc43473a","orderId":"d0a0fcd7-1e90-4893-a46b-fc53f46d84f2"},"createdAt":"2024-09-13T17:41:59.076Z"}
        
        guard let jsonData = try JSONSerialization.jsonObject(with: decrypted, options: []) as? [String: Any] else {
            Logger.error("Failed to convert decrypted data to utf8")
            return
        }
        
        let orderPaymentConfirmed = jsonData["type"] as? String
        guard let payload = jsonData["payload"] as? [String: Any] else {
            Logger.error("Missing payload")
            return
        }
        
        if orderPaymentConfirmed == "orderPaymentConfirmed" {
            Logger.debug("Order payment confirmed")
            
            guard let orderId = payload["orderId"] as? String else {
                Logger.error("Missing orderId")
                return
            }
            
            Logger.debug("orderId: \(orderId)")
            
            // TODO: trigger channel open
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
            self.bestAttemptContent?.title = "Payment received"
            self.bestAttemptContent?.body = "Via new channel"

            if let channel = LightningService.shared.channels?.first { $0.channelId == channelId } {
                self.bestAttemptContent?.title = "Received ⚡ \(channel.outboundCapacityMsat / 1000) sats"
            }
            
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
        case .paymentClaimable:
            break
        case .paymentFailed(paymentId: let paymentId, paymentHash: let paymentHash, reason: let reason):
            self.bestAttemptContent?.title = "Payment failed"
            self.bestAttemptContent?.body = reason.debugDescription ?? "Unknown"
            Task {
                await self.deliver()
            }
        }
    }
    
    func deliver() async {
        try? await LightningService.shared.stop()
        self.nodeStopTime = CFAbsoluteTimeGetCurrent()
        
        self.logPerformance()
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
    
    func logPerformance() {
        guard let receieveTime else {
            return
        }
        
        guard let nodeStartedTime else {
            return
        }
        
        let nodeStartSeconds = Double(round(100 * (nodeStartedTime - receieveTime)) / 100)
        Logger.performance("Node start time \(nodeStartSeconds) seconds")
        
        guard let lightningEventTime else {
            return
        }
        
        let lightningEventSeconds = Double(round(100 * (lightningEventTime - nodeStartedTime)) / 100)
        Logger.performance("Lightning event time \(lightningEventSeconds) seconds from node startup")
        
        guard let nodeStopTime else {
            return
        }
        
        let nodeStopSeconds = Double(round(100 * (nodeStopTime - lightningEventTime)) / 100)
        Logger.performance("Node stop time \(lightningEventSeconds) seconds from lightning event")
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
