import SwiftUI

// MARK: - Quick Action Notification

/// Communication bridge between delegates and SwiftUI views
extension Notification.Name {
    static let quickActionSelected = Notification.Name("quickActionSelected")
    static let deepLinkReceived = Notification.Name("deepLinkReceived")
    static let paykitSubscriptionPaymentDue = Notification.Name("paykitSubscriptionPaymentDue")
}

struct PaykitSubscriptionNotificationTarget: Codable, Equatable {
    let payerIdentity: String
    let paymentRequestId: String
    let counterparty: String
    let counterpartyReceiverPath: String
    let billingPeriodStartsAt: String

    init?(userInfo: [AnyHashable: Any]) {
        guard let payerIdentity = userInfo["payer_identity"] as? String,
              let paymentRequestId = userInfo["payment_request_id"] as? String,
              let counterparty = userInfo["counterparty"] as? String,
              let counterpartyReceiverPath = userInfo["counterparty_receiver_path"] as? String,
              let billingPeriodStartsAt = userInfo["billing_period_starts_at"] as? String
        else { return nil }

        self.payerIdentity = payerIdentity
        self.paymentRequestId = paymentRequestId
        self.counterparty = counterparty
        self.counterpartyReceiverPath = counterpartyReceiverPath
        self.billingPeriodStartsAt = billingPeriodStartsAt
    }

    func matches(_ request: PaykitPaymentRequest) -> Bool {
        paymentRequestId == request.paymentRequestId &&
            PubkyPublicKeyFormat.matches(counterparty, request.counterparty) &&
            counterpartyReceiverPath == request.counterpartyReceiverPath &&
            request.billingPeriod.map {
                PaykitSubscriptionTimestamp.string(from: $0.startsAt) == billingPeriodStartsAt
            } == true
    }

    func matches(_ requestId: PaykitPaymentRequest.ID) -> Bool {
        paymentRequestId == requestId.paymentRequestId &&
            PubkyPublicKeyFormat.matches(counterparty, requestId.counterparty) &&
            counterpartyReceiverPath == requestId.counterpartyReceiverPath &&
            requestId.billingPeriodStartsAt.map {
                PaykitSubscriptionTimestamp.string(from: $0) == billingPeriodStartsAt
            } == true
    }

    func matches(identity: String) -> Bool {
        PubkyPublicKeyFormat.matches(payerIdentity, identity)
    }
}

enum PaykitSubscriptionNotificationTargetStore {
    private static let key = "paykitSubscriptionNotificationTarget"

    static func save(_ target: PaykitSubscriptionNotificationTarget) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PaykitSubscriptionNotificationTarget? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PaykitSubscriptionNotificationTarget.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    // MARK: - App Launch

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        recordLaunchProbe(launchOptions: launchOptions)
        UNUserNotificationCenter.current().delegate = self

        // Check notification authorization status at launch and re-register with APN if granted
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }

        return true
    }

    private func recordLaunchProbe(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let result: [String: Any] = [
            "launchedAt": ISO8601DateFormatter().string(from: Date()),
            "processId": ProcessInfo.processInfo.processIdentifier,
            "remoteNotificationLaunchOption": launchOptions?[.remoteNotification] != nil,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            try data.write(to: documents.appendingPathComponent("background-wake-launch.json"), options: .atomic)
        } catch {
            Logger.error(error, context: "AppDelegate")
        }
    }

    // MARK: - Scene Configuration

    /// Required for SwiftUI apps to handle quick actions
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        DeepLinkRouter.shared.forward(url)
        return true
    }

    // MARK: - App Termination

    func applicationWillTerminate(_ application: UIApplication) {
        try? StateLocker.unlock(.lightning)
    }
}

// MARK: - Push Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        PushNotificationManager.shared.updateDeviceToken(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.error("🔔 AppDelegate: didFailToRegisterForRemoteNotificationsWithError: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let isPaymentWake = userInfo["bitkit_wake_payment"] as? Int == 1
        guard let probeId = (userInfo["bitkit_wake_probe"] as? String) ?? (isPaymentWake ? UUID().uuidString : nil) else {
            completionHandler(.noData)
            return
        }

        Task { @MainActor in
            let receivedAt = Date()
            let initialNodeRunning = LightningService.shared.status?.isRunning
            let appState = switch application.applicationState {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }

            var result: [String: Any] = [
                "probeId": probeId,
                "trigger": isPaymentWake ? "payment" : "probe",
                "receivedAt": ISO8601DateFormatter().string(from: receivedAt),
                "processId": ProcessInfo.processInfo.processIdentifier,
                "appState": appState,
                "initialNodeRunning": initialNodeRunning.map { $0 as Any } ?? NSNull(),
            ]
            guard recordWakeProbe(result) else {
                completionHandler(.failed)
                return
            }

            var nodeRunning = initialNodeRunning
            for _ in 0 ..< 20 where nodeRunning != true {
                try? await Task.sleep(for: .seconds(1))
                nodeRunning = LightningService.shared.status?.isRunning
            }

            var paymentObserved = false
            result["finalNodeRunning"] = nodeRunning.map { $0 as Any } ?? NSNull()
            if nodeRunning == true {
                await LightningService.shared.refreshCache()
                result["connectedPeersBeforeReconnect"] = LightningService.shared.peers?.filter(\.isConnected).count ?? 0
                guard recordWakeProbe(result) else {
                    completionHandler(.failed)
                    return
                }

                await LightningService.shared.reconnectPeers()
                await LightningService.shared.refreshCache()
                result["connectedPeersAfterReconnect"] = LightningService.shared.peers?.filter(\.isConnected).count ?? 0
                let initialSettledPayments = await LightningService.shared.listPayments()?.filter {
                    $0.direction == .inbound && $0.status == .succeeded
                }.count ?? 0
                result["settledInboundPaymentsBeforeWait"] = initialSettledPayments
                guard recordWakeProbe(result) else {
                    completionHandler(.failed)
                    return
                }

                // Leave time for the completion handler before iOS's roughly 30-second background limit.
                while Date().timeIntervalSince(receivedAt) < 23 {
                    try? await Task.sleep(for: .seconds(2))
                    let settledPayments = await LightningService.shared.listPayments()?.filter {
                        $0.direction == .inbound && $0.status == .succeeded
                    }.count ?? initialSettledPayments
                    result["settledInboundPaymentsAfterWait"] = settledPayments
                    if settledPayments > initialSettledPayments {
                        paymentObserved = true
                        break
                    }
                }
            }
            result["paymentObserved"] = paymentObserved
            result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            guard recordWakeProbe(result) else {
                completionHandler(.failed)
                return
            }

            Logger.info("Handled background wake '\(probeId)' with node running '\(nodeRunning == true)'", context: "AppDelegate")
            completionHandler(paymentObserved ? .newData : .noData)
        }
    }

    private func recordWakeProbe(_ result: [String: Any]) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: result)
        else { return false }

        do {
            try data.write(to: documents.appendingPathComponent("background-wake-probe.json"), options: .atomic)
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bitkit") {
                try? data.write(to: container.appendingPathComponent("background-wake-probe.json"), options: .atomic)
            }
            return true
        } catch {
            Logger.error(error, context: "AppDelegate")
            return false
        }
    }

    /// Foreground notification presentation
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        Logger.debug("🔔 AppDelegate: willPresent notification called")
        Logger.debug("🔔 AppDelegate: UserInfo: \(userInfo)")
        Logger.debug("🔔 AppDelegate: Notification content: \(notification.request.content)")

        completionHandler([[.banner, .badge, .sound]])
    }

    /// Handle taps on notifications
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if userInfo["bitkit_action"] as? String == "paykit_subscription_due" {
            if let target = PaykitSubscriptionNotificationTarget(userInfo: userInfo) {
                PaykitSubscriptionNotificationTargetStore.save(target)
            }
            NotificationCenter.default.post(name: .paykitSubscriptionPaymentDue, object: nil, userInfo: userInfo)
        } else {
            PushNotificationManager.shared.handleNotification(userInfo)
        }

        // TODO: if user tapped on an incoming tx we should open it on that tx view
        completionHandler()
    }
}

// MARK: - SwiftUI App

@main
struct BitkitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        UIWindow.appearance().overrideUserInterfaceStyle = .dark
        if Env.shouldResetTrezorEmulatorState {
            TrezorKnownDeviceStorage.removeAll()
            TrezorCredentialStorage.deleteAll()
        }
        _ = ToastWindowManager.shared
    }

    var body: some Scene {
        WindowGroup {
            if Env.isUnitTest, !Env.isTrezorEmulatorTesting {
                Text("Running tests...")
            } else {
                ContentView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
