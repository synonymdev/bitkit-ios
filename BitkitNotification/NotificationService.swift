import LDKNode
import os.log
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    let walletIndex = 0 // Assume first wallet for now

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    var receiveTime: CFAbsoluteTime?
    var nodeStartedTime: CFAbsoluteTime?
    var lightningEventTime: CFAbsoluteTime?
    var nodeStopTime: CFAbsoluteTime?

    var notificationType: BlocktankNotificationType?
    var notificationPayload: [String: Any]?

    private lazy var notificationLogger: OSLog = {
        let bundleID = Bundle.main.bundleIdentifier ?? "to.bitkit-regtest.notification"
        return OSLog(subsystem: bundleID, category: "NotificationService")
    }()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        os_log("🚨 Push received! %{public}@", log: notificationLogger, type: .error, request.identifier)
        os_log("🔔 UserInfo: %{public}@", log: notificationLogger, type: .error, request.content.userInfo)

        receiveTime = CFAbsoluteTimeGetCurrent()

        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard !StateLocker.isLocked(.lightning) else {
            os_log("🔔 LDK-node process already locked, app likely in foreground", log: notificationLogger, type: .error)
            return
        }

        Task {
            // Ensure lock is released even if task is cancelled or errors occur
            defer {
                // Fallback: unlock in case stop() wasn't called
                try? StateLocker.unlock(.lightning)
                os_log("🔔 Task cleanup: ensured lock release", log: notificationLogger, type: .error)
            }

            do {
                try await self.decryptPayload(request)
                os_log("🔔 Decryption successful. Type: %{public}@", log: notificationLogger, type: .error, self.notificationType?.rawValue ?? "nil")
            } catch {
                // Don't cancel the notification if this fails, rather let the node spin up and handle any potential events
                os_log(
                    "🔔 Failed to decrypt notification payload: %{public}@",
                    log: notificationLogger,
                    type: .error,
                    error.localizedDescription
                )
            }

            do {
                // TODO: switch to electrum after syncing issues are fixed
                // For notification extension, use default Electrum server URL for now
                // try await LightningService.shared.setup(walletIndex: self.walletIndex, electrumServerUrl: Env.electrumServerUrl)

                try await LightningService.shared.setup(walletIndex: self.walletIndex)
                try await LightningService.shared.start { event in
                    self.lightningEventTime = CFAbsoluteTimeGetCurrent()
                    self.handleLdkEvent(event: event)
                }

                self.nodeStartedTime = CFAbsoluteTimeGetCurrent()
                os_log("🔔 Lightning node started successfully", log: notificationLogger, type: .error)
            } catch {
                self.bestAttemptContent?.title = "Lightning Error"
                self.bestAttemptContent?.body = error.localizedDescription

                os_log(
                    "🔔 NotificationService: Failed to setup node in notification service: %{public}@",
                    log: notificationLogger,
                    type: .error,
                    error.localizedDescription
                )
                self.dumpLdkLogs()
                self.deliver()
            }

            // Once node is started, handle the manual channel opening if needed
            if self.notificationType == .orderPaymentConfirmed {
                guard let orderId = notificationPayload?["orderId"] as? String else {
                    os_log("🔔 NotificationService: Missing orderId", log: notificationLogger, type: .error)
                    return
                }

                os_log("🔔 NotificationService: Open channel request for order %{public}@", log: notificationLogger, type: .error, orderId)

                do {
                    let order = try await CoreService.shared.blocktank.open(orderId: orderId)
                    os_log("🔔 NotificationService: Channel opened for order %{public}@", log: notificationLogger, type: .error, order.id)
                } catch {
                    logError(error, context: "Failed to open channel")

                    self.bestAttemptContent?.title = "Spending Balance Setup Failed"
                    self.bestAttemptContent?.body = error.localizedDescription

                    self.deliver()
                }
            }
        }
    }

    func decryptPayload(_ request: UNNotificationRequest) async throws {
        guard let aps = request.content.userInfo["aps"] as? AnyObject else {
            os_log("🔔 Failed to decrypt payload: missing aps payload", log: notificationLogger, type: .error)
            return
        }

        guard let alert = aps["alert"] as? AnyObject,
              let payload = alert["payload"] as? AnyObject,
              let cipher = payload["cipher"] as? String,
              let iv = payload["iv"] as? String,
              let publicKey = payload["publicKey"] as? String,
              let tag = payload["tag"] as? String
        else {
            os_log("🔔 Failed to decrypt payload: missing details", log: notificationLogger, type: .error)
            return
        }

        guard let ciphertext = Data(base64Encoded: cipher) else {
            os_log("🔔 Failed to decrypt payload: failed to decode cipher", log: notificationLogger, type: .error)
            return
        }

        guard let privateKey = try Keychain.load(key: .pushNotificationPrivateKey) else {
            os_log("🔔 Failed to decrypt payload: missing pushNotificationPrivateKey", log: notificationLogger, type: .error)
            return
        }

        let password = try Crypto.generateSharedSecret(privateKey: privateKey, nodePubkey: publicKey, derivationName: "bitkit-notifications")
        let decrypted = try Crypto.decrypt(.init(cipher: ciphertext, iv: iv.hexaData, tag: tag.hexaData), secretKey: password)

        os_log("🔔 Decrypted payload: %{public}@", log: notificationLogger, type: .error, String(data: decrypted, encoding: .utf8) ?? "")

        guard let jsonData = try JSONSerialization.jsonObject(with: decrypted, options: []) as? [String: Any] else {
            os_log("🔔 Failed to decrypt payload: failed to convert decrypted data to utf8", log: notificationLogger, type: .error)
            return
        }

        guard let payload = jsonData["payload"] as? [String: Any] else {
            os_log("🔔 Failed to decrypt payload: missing payload", log: notificationLogger, type: .error)
            return
        }

        guard let typeStr = jsonData["type"] as? String, let type = BlocktankNotificationType(rawValue: typeStr) else {
            os_log("🔔 Failed to decrypt payload: missing type", log: notificationLogger, type: .error)
            return
        }

        notificationType = type
        notificationPayload = payload
    }

    /// Listen for LDK events and if the event matches the notification type then deliver the notification
    /// - Parameter event
    func handleLdkEvent(event: Event) {
        os_log("🔔 New LDK event: %{public}@", log: notificationLogger, type: .error, String(describing: event))

        switch event {
        case let .paymentReceived(_, _, amountMsat, _):
            let sats = amountMsat / 1000
            bestAttemptContent?.title = "Payment Received"
            bestAttemptContent?.body = "₿ \(sats)"
            ReceivedTxSheetDetails(type: .lightning, sats: sats).save() // Save for UI to pick up

            if notificationType == .incomingHtlc {
                deliver()
            }
        case .channelPending:
            bestAttemptContent?.title = "Spending Balance Ready"
            bestAttemptContent?.body = "Pending"
        // Don't deliver, give a chance for channelReady event to update the content if it's a turbo channel
        case let .channelReady(channelId, _, _):
            if notificationType == .cjitPaymentArrived {
                bestAttemptContent?.title = "Payment Received"
                bestAttemptContent?.body = "Your funds arrived in your spending balance"

                os_log("🔔 NotificationService: cjitPaymentArrived", log: notificationLogger, type: .error)

                if let channel = LightningService.shared.channels?.first(where: { $0.channelId == channelId }) {
                    os_log("🔔 NotificationService: Channel found", log: notificationLogger, type: .error)
                    let sats = channel.outboundCapacityMsat / 1000 + (channel.unspendablePunishmentReserve ?? 0)
                    bestAttemptContent?.title = "Payment Received"
                    bestAttemptContent?.body = "₿ \(sats)"
                    ReceivedTxSheetDetails(type: .lightning, sats: sats).save() // Save for UI to pick up
                }

                deliver()
            } else if notificationType == .orderPaymentConfirmed {
                bestAttemptContent?.title = "Spending Balance Ready"
                bestAttemptContent?.body = "Open Bitkit to start paying anyone, anywhere."
                deliver()
            }
        case .channelClosed:
            if notificationType == .mutualClose {
                bestAttemptContent?.title = "Spending Balance Expired"
                bestAttemptContent?.body = "Your funds moved from spending to savings"
                deliver()
            } else if notificationType == .orderPaymentConfirmed {
                bestAttemptContent?.title = "Spending Balance Setup Failed"
                bestAttemptContent?.body = "Please open Bitkit and try again"
                deliver()
            }
        case .paymentSuccessful:
            break
        case .paymentClaimable:
            break
        case let .paymentFailed(_, _, reason):
            bestAttemptContent?.title = "Payment Failed"
            bestAttemptContent?.body = reason.debugDescription

            if notificationType == .wakeToTimeout {
                deliver()
            }
        case .paymentForwarded:
            break
        }
    }

    func deliver() {
        Task {
            // Sleep to allow event to be processed
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try? await LightningService.shared.stop()

            self.nodeStopTime = CFAbsoluteTimeGetCurrent()
            self.logPerformance()

            if let contentHandler, let bestAttemptContent {
                contentHandler(bestAttemptContent)
                os_log("🔔 Notification delivered successfully", log: notificationLogger, type: .error)
            } else {
                os_log("🔔 Missing contentHandler or bestAttemptContent", log: notificationLogger, type: .error)
            }
        }
    }

    func logPerformance() {
        guard let receiveTime else { return }
        guard let nodeStartedTime else { return }

        let nodeStartSeconds = Double(round(100 * (nodeStartedTime - receiveTime)) / 100)
        os_log("⏱️ Node start time: %{public}f seconds", log: notificationLogger, type: .error, nodeStartSeconds)

        guard let lightningEventTime else { return }

        let lightningEventSeconds = Double(round(100 * (lightningEventTime - nodeStartedTime)) / 100)
        os_log("⏱️ Lightning event time: %{public}f seconds from node startup", log: notificationLogger, type: .error, lightningEventSeconds)

        guard let nodeStopTime else { return }

        let nodeStopSeconds = Double(round(100 * (nodeStopTime - lightningEventTime)) / 100)
        os_log("⏱️ Node stop time: %{public}f seconds from lightning event", log: notificationLogger, type: .error, nodeStopSeconds)
    }

    func dumpLdkLogs() {
        let dir = Env.ldkStorage(walletIndex: walletIndex)
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")

        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            os_log("📋 LDK-NODE LOG (last 20 lines):", log: notificationLogger, type: .error)
            for line in lines.suffix(20) {
                os_log("📋 %{public}@", log: notificationLogger, type: .error, line)
            }
        } catch {
            os_log("🔔 Failed to load LDK log file: %{public}@", log: notificationLogger, type: .error, error.localizedDescription)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        os_log("🔔 NotificationService: Delivering notification before timeout", log: notificationLogger, type: .error)

        // Try to stop node and release lock before termination
        Task {
            try? await LightningService.shared.stop()
        }

        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    /// Logs comprehensive error details
    private func logError(_ error: Error, context: String) {
        os_log(
            "❌ %{public}@: %{public}@",
            log: notificationLogger,
            type: .error,
            context,
            String(describing: error)
        )
    }
}
