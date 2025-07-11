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

    var notificationType: BlocktankNotificationType?
    var notificationPayload: [String: Any]?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.receieveTime = CFAbsoluteTimeGetCurrent()

        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard !StateLocker.isLocked(.lightning) else {
            Logger.info("LDK-node process already locked, app likely in foreground")
            self.bestAttemptContent?.title = "Lightning process already locked"
            self.bestAttemptContent?.body = "App likely in foreground"
            self.deliver()
            return
        }

        Task {
            Logger.debug("Received notification")
            do {
                try await self.decryptPayload(request)
            } catch {
                // Don't cancel the notification if this fails, rather let the node spin up and handle any potential events
                Logger.error(error, context: "Failed to read notification payment")
            }

            do {
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
                self.deliver()
            }

            // Once node is started, handle the manual channel opening if needed
            if self.notificationType == .orderPaymentConfirmed {
                guard let orderId = notificationPayload?["orderId"] as? String else {
                    Logger.error("Missing orderId")
                    return
                }

                do {
                    let order = try await CoreService.shared.blocktank.open(orderId: orderId)
                    Logger.info("Open channel request for order \(orderId)")
                } catch {
                    Logger.error(error, context: "failed to open channel")
                    self.bestAttemptContent?.title = "Channel open failed"
                    self.bestAttemptContent?.body = error.localizedDescription
                    self.deliver()
                }
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

        guard let payload = jsonData["payload"] as? [String: Any] else {
            Logger.error("Missing payload")
            return
        }

        guard let typeStr = jsonData["type"] as? String, let type = BlocktankNotificationType(rawValue: typeStr) else {
            Logger.error("Missing type")
            return
        }

        self.notificationType = type
        self.notificationPayload = payload
    }

    /// Listen for LDK events and if the event matches the notification type then deliver the notification
    /// - Parameter event
    func handleLdkEvent(event: Event) {
        switch event {
        case .paymentReceived(let paymentId, let paymentHash, let amountMsat, let customRecords):
            self.bestAttemptContent?.title = "Payment Received"
            let sats = amountMsat / 1000
            self.bestAttemptContent?.body = "⚡ \(sats)"
            ReceivedTxSheetDetails(type: .lightning, sats: sats).save() // Save for UI to pick up

            if self.notificationType == .incomingHtlc {
                self.deliver()
            }
        case .channelPending(let channelId, let userChannelId, let formerTemporaryChannelId, let counterpartyNodeId, let fundingTxo):
            self.bestAttemptContent?.title = "Channel Opened"
            self.bestAttemptContent?.body = "Pending"
        // Don't deliver, give a chance for channelReady event to update the content if it's a turbo channel
        case .channelReady(let channelId, let userChannelId, let counterpartyNodeId):
            if self.notificationType == .cjitPaymentArrived {
                self.bestAttemptContent?.title = "Payment received"
                self.bestAttemptContent?.body = "Via new channel"

                if let channel = LightningService.shared.channels?.first(where: { $0.channelId == channelId }) {
                    let sats = channel.inboundCapacityMsat / 1000
                    self.bestAttemptContent?.title = "Received ⚡ \(sats) sats"
                    ReceivedTxSheetDetails(type: .lightning, sats: sats).save() // Save for UI to pick u
                }
            } else if self.notificationType == .orderPaymentConfirmed {
                self.bestAttemptContent?.title = "Channel opened"
                self.bestAttemptContent?.body = "Ready to send"
            }
            self.deliver()
        case .channelClosed(let channelId, let userChannelId, let counterpartyNodeId, let reason):
            if self.notificationType == .mutualClose {
                self.bestAttemptContent?.title = "Channel closed"
                self.bestAttemptContent?.body = "Balance moved from spending to savings"
            } else if self.notificationType == .orderPaymentConfirmed {
                self.bestAttemptContent?.title = "Channel failed to open in the background"
                self.bestAttemptContent?.body = "Please try again"
            }

            self.deliver()
        case .paymentSuccessful:
            break
        case .paymentClaimable:
            break
        case .paymentFailed(let paymentId, let paymentHash, let reason):
            self.bestAttemptContent?.title = "Payment failed"
            self.bestAttemptContent?.body = reason.debugDescription

            if self.notificationType == .wakeToTimeout {
                self.deliver()
            }
        case .paymentForwarded(_, _, _, _, _, _, _, _, _, _):
            break
        }
    }

    func deliver() {
        Task {
            //Sleep to allow event to be processed
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try? await LightningService.shared.stop()
            self.nodeStopTime = CFAbsoluteTimeGetCurrent()

            self.logPerformance()
            if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
                contentHandler(bestAttemptContent)
                Logger.info("Delivered notification")
            }
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
        Logger.performance("Node stop time \(nodeStopSeconds) seconds from lightning event")
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
