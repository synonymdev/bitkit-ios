import SwiftUI

// MARK: - Quick Action Notification

/// Communication bridge between delegates and SwiftUI views
extension Notification.Name {
    static let quickActionSelected = Notification.Name("quickActionSelected")
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
