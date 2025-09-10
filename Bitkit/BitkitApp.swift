import SwiftUI

// MARK: - Quick Action Notification

// Communication bridge between delegates and SwiftUI views
extension Notification.Name {
    static let quickActionSelected = Notification.Name("quickActionSelected")
}

class AppDelegate: NSObject, UIApplicationDelegate {
    // MARK: - App Launch

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - Scene Configuration

    // Required for SwiftUI apps to handle quick actions
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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        Logger.debug(userInfo, context: "push notification received while app is in the foreground")

        completionHandler([])
        // completionHandler([[.banner, .badge, .sound]])
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02hhx", $0) }.joined()

        Task {
            do {
                try await NotificationService.shared.registerDeviceForNotifications(deviceToken: tokenString)
            } catch {
                Logger.error("Failed to register device token with server: \(error)")
                await MainActor.run {
                    NotificationService.shared.onRegistrationStatusChanged?(false)
                    NotificationService.shared.onRegistrationFailed?(error)
                }
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.error(error)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        Logger.debug(userInfo, context: "app opened from push notification")
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
        _ = ToastWindowManager.shared
    }

    var body: some Scene {
        WindowGroup {
            if Env.isUnitTest {
                Text("Running tests...")
            } else {
                ContentView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
