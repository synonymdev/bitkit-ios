import SwiftUI
import UIKit

// MARK: - Scene Delegate for Quick Actions & URL Handling

// Handles scene lifecycle, quick actions, and URL callbacks for SwiftUI apps
class SceneDelegate: NSObject, UIWindowSceneDelegate {
    // MARK: - Quick Action State

    var savedShortCutItem: UIApplicationShortcutItem?
    
    // Saved URL for when scene becomes active
    var savedURL: URL?

    // MARK: - Scene Connection

    // Save quick action when scene is created
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            savedShortCutItem = shortcutItem
        }
        
        // Handle URLs passed at scene creation
        if let urlContext = connectionOptions.urlContexts.first {
            savedURL = urlContext.url
        }
    }

    // MARK: - Scene Activation

    // Handle saved quick action and URL when scene becomes active
    func sceneDidBecomeActive(_ scene: UIScene) {
        if let shortcutItem = savedShortCutItem {
            handleQuickAction(shortcutItem)
            savedShortCutItem = nil
        }
        
        // Handle saved URL
        if let url = savedURL {
            handleURL(url)
            savedURL = nil
        }
    }
    
    // MARK: - URL Handling
    
    // Handle URLs when app is already running
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let urlContext = URLContexts.first else { return }
        handleURL(urlContext.url)
    }
    
    // Process URL and route to appropriate handler
    private func handleURL(_ url: URL) {
        // Route bitkit:// URLs to PubkyRingBridge for Paykit/Pubky-ring callbacks
        if url.scheme == "bitkit" {
            Logger.info("SceneDelegate: Received bitkit:// URL: \(url.absoluteString)", context: "SceneDelegate")
            _ = PubkyRingBridge.shared.handleCallback(url: url)
        }
    }

    // MARK: - Quick Action Handling (App Running)

    // Handle quick action when app is already running
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        handleQuickAction(shortcutItem)
        completionHandler(true)
    }

    // MARK: - Quick Action Processing

    // Process quick action and notify SwiftUI views
    private func handleQuickAction(_ shortcutItem: UIApplicationShortcutItem) {
        let userInfo = ["shortcutType": shortcutItem.type]
        NotificationCenter.default.post(name: .quickActionSelected, object: nil, userInfo: userInfo)
    }
}
