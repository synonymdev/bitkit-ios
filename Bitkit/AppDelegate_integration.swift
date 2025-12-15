//
//  AppDelegate Integration for PIP SDK
//
//  Add these methods to your AppDelegate.swift
//

import UIKit
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            } else if let error = error {
                print("Notification permission error: \(error)")
            }
        }
        
        // Initialize PIP background handler
        let config = createPipConfig()
        PipBackgroundHandler.shared.initialize(config: config)
        
        return true
    }
    
    // MARK: - APNs Registration
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("APNs token: \(tokenString)")
        
        // TODO: Send token to PIP receiver for push notifications
        // Store in UserDefaults for now
        UserDefaults.standard.set(tokenString, forKey: "apns_token")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }
    
    // MARK: - Silent Push Handling
    
    func application(_ application: UIApplication,
                    didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        
        print("Received remote notification")
        
        // Delegate to PIP background handler
        PipBackgroundHandler.shared.application(
            application,
            didReceiveRemoteNotification: userInfo,
            fetchCompletionHandler: completionHandler
        )
    }
    
    // MARK: - PIP Config
    
    private func createPipConfig() -> PipConfig {
        // Load or generate HMAC key
        let sessionStore = PipSessionStore(config: PipConfig(
            stateDir: getStateDir(),
            esploraUrls: getEsploraUrls(),
            useTor: false,
            webhookHmacKey: [],
            tofuMode: "DualPinGrace"
        ))
        
        let hmacKey: Data
        if let existingKey = sessionStore.loadHmacKey() {
            hmacKey = existingKey
        } else {
            hmacKey = sessionStore.generateAndSaveHmacKey()
        }
        
        return PipConfig(
            stateDir: getStateDir(),
            esploraUrls: getEsploraUrls(),
            useTor: false,
            webhookHmacKey: [UInt8](hmacKey),
            tofuMode: "DualPinGrace"
        )
    }
    
    private func getStateDir() -> String {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let pipDir = documentsDirectory.appendingPathComponent("pip")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: pipDir, withIntermediateDirectories: true)
        
        return pipDir.path
    }
    
    private func getEsploraUrls() -> [String] {
        return [
            "https://blockstream.info/api",
            "https://mempool.space/api",
            "https://mempool.emzy.de/api"
        ]
    }
}
