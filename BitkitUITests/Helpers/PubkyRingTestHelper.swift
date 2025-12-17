//
//  PubkyRingTestHelper.swift
//  BitkitUITests
//
//  Test helper for simulating Pubky-ring app interactions in E2E tests
//

import XCTest

/// Helper for simulating Pubky-ring app interactions in E2E tests
class PubkyRingTestHelper {
    
    // MARK: - Test Data
    
    /// Test pubkey for E2E tests
    static let testPubkey = "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK"
    
    /// Test session secret
    static let testSessionSecret = "test_session_secret_\(UUID().uuidString)"
    
    /// Test device ID
    static let testDeviceId = "test_device_\(UUID().uuidString)"
    
    // MARK: - Session Simulation
    
    /// Create a test session for E2E tests
    static func createTestSession(
        pubkey: String = testPubkey,
        expiresInHours: Int = 24
    ) -> [String: Any] {
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresInHours * 3600))
        return [
            "pubkey": pubkey,
            "session_secret": testSessionSecret,
            "capabilities": ["read", "write"],
            "expires_at": expiresAt.timeIntervalSince1970
        ]
    }
    
    /// Simulate a session callback from Pubky-ring
    static func simulateSessionCallback(
        app: XCUIApplication,
        pubkey: String = testPubkey,
        sessionSecret: String = testSessionSecret
    ) {
        let callbackUrl = "bitkit://paykit-session?pubky=\(pubkey)&session_secret=\(sessionSecret)"
        
        // Open the callback URL to simulate Pubky-ring response
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.textFields["URL"].tap()
        safari.typeText(callbackUrl)
        safari.buttons["Go"].tap()
        
        // Wait for Bitkit to handle the callback
        sleep(2)
    }
    
    // MARK: - Keypair Simulation
    
    /// Create a test keypair for E2E tests
    static func createTestKeypair() -> [String: String] {
        // Generate deterministic test keys
        let secretKey = String(repeating: "a1", count: 32)
        let publicKey = String(repeating: "b2", count: 32)
        return [
            "secret_key": secretKey,
            "public_key": publicKey
        ]
    }
    
    /// Simulate a keypair callback from Pubky-ring
    static func simulateKeypairCallback(
        app: XCUIApplication,
        deviceId: String = testDeviceId,
        epoch: Int = 0
    ) {
        let keypair = createTestKeypair()
        let callbackUrl = "bitkit://paykit-keypair?public_key=\(keypair["public_key"]!)&secret_key=\(keypair["secret_key"]!)&device_id=\(deviceId)&epoch=\(epoch)"
        
        // Open the callback URL
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.textFields["URL"].tap()
        safari.typeText(callbackUrl)
        safari.buttons["Go"].tap()
        
        sleep(2)
    }
    
    // MARK: - Profile Simulation
    
    /// Create a test profile
    static func createTestProfile(
        name: String = "Test User",
        bio: String = "Test bio for E2E tests"
    ) -> [String: Any] {
        return [
            "name": name,
            "bio": bio,
            "image": "https://example.com/avatar.png",
            "links": [
                ["title": "Website", "url": "https://example.com"]
            ]
        ]
    }
    
    // MARK: - App Detection
    
    /// Check if Pubky-ring app is installed
    static func isPubkyRingInstalled() -> Bool {
        let pubkyRing = XCUIApplication(bundleIdentifier: "to.pubky.ring")
        return pubkyRing.exists
    }
    
    /// Launch Pubky-ring app if installed
    static func launchPubkyRing() -> XCUIApplication? {
        guard isPubkyRingInstalled() else { return nil }
        let pubkyRing = XCUIApplication(bundleIdentifier: "to.pubky.ring")
        pubkyRing.launch()
        return pubkyRing
    }
    
    // MARK: - Wait Helpers
    
    /// Wait for a callback to be processed
    static func waitForCallback(
        app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        // Wait for app to return to foreground after callback
        let predicate = NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
    
    /// Wait for an element to appear
    static func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        return element.waitForExistence(timeout: timeout)
    }
}

// MARK: - Test Data Factory

/// Factory for creating consistent test data
struct TestDataFactory {
    
    /// Generate a unique test pubkey
    static func generatePubkey() -> String {
        return "z6Mk\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(44))"
    }
    
    /// Generate a unique device ID
    static func generateDeviceId() -> String {
        return UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
    
    /// Generate a test session secret
    static func generateSessionSecret() -> String {
        return UUID().uuidString + UUID().uuidString
    }
    
    /// Generate test hex keypair
    static func generateHexKeypair() -> (secretKey: String, publicKey: String) {
        let chars = "0123456789abcdef"
        let secretKey = String((0..<64).map { _ in chars.randomElement()! })
        let publicKey = String((0..<64).map { _ in chars.randomElement()! })
        return (secretKey, publicKey)
    }
}

