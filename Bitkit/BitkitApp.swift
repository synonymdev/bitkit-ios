import SwiftUI

// MARK: - Quick Action Notification

// Communication bridge between delegates and SwiftUI views
extension Notification.Name {
    static let quickActionSelected = Notification.Name("quickActionSelected")
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
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        PushNotificationManager.shared.updateDeviceToken(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.error("🔔 AppDelegate: didFailToRegisterForRemoteNotificationsWithError: \(error)")
    }

    // Foreground notification presentation
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

    // Handle taps on notifications
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        PushNotificationManager.shared.handleNotification(userInfo)

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
