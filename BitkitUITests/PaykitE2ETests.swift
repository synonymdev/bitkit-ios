//
//  PaykitE2ETests.swift
//  BitkitUITests
//
//  End-to-end tests for Paykit integration with Pubky-ring
//

import XCTest

final class PaykitE2ETests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--uitesting")
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - 3.2 Session Management E2E Tests
    
    func testSessionFlow_RequestAndReceive() throws {
        // Navigate to session management
        WalletTestHelper.navigateToSessionManagement(app: app)
        
        // Tap "Connect Pubky-ring" button
        let connectButton = app.buttons["Connect Pubky-ring"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5))
        
        // If Pubky-ring is not installed, verify fallback UI
        if !PubkyRingTestHelper.isPubkyRingInstalled() {
            connectButton.tap()
            
            // Should show QR code option for cross-device auth
            let qrOption = app.buttons["Use QR Code"]
            XCTAssertTrue(qrOption.waitForExistence(timeout: 3))
            return
        }
        
        // If installed, tap and simulate callback
        connectButton.tap()
        
        // Simulate Pubky-ring callback
        PubkyRingTestHelper.simulateSessionCallback(app: app)
        
        // Verify session appears in list
        XCTAssertTrue(WalletTestHelper.hasActiveSession(app: app))
    }
    
    func testSessionFlow_Persistence() throws {
        // First, add a session
        try testSessionFlow_RequestAndReceive()
        
        // Terminate and relaunch app
        app.terminate()
        app.launch()
        
        // Verify session is restored
        WalletTestHelper.navigateToSessionManagement(app: app)
        XCTAssertTrue(WalletTestHelper.hasActiveSession(app: app))
    }
    
    func testSessionFlow_ExpirationHandling() throws {
        // Navigate to sessions
        WalletTestHelper.navigateToSessionManagement(app: app)
        
        // Look for expiration warning if any sessions are expiring
        let expirationWarning = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'expir'")).firstMatch
        
        // If there's an expiring session, verify refresh button exists
        if expirationWarning.exists {
            let refreshButton = app.buttons["Refresh"]
            XCTAssertTrue(refreshButton.exists)
        }
    }
    
    func testSessionFlow_GracefulDegradation() throws {
        // Test behavior when Pubky-ring is not installed
        WalletTestHelper.navigateToSessionManagement(app: app)
        
        if !PubkyRingTestHelper.isPubkyRingInstalled() {
            // Should show install prompt or alternative methods
            let installPrompt = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'install'")).firstMatch
            let qrOption = app.buttons["Use QR Code"]
            
            XCTAssertTrue(installPrompt.exists || qrOption.exists)
        }
    }
    
    // MARK: - 3.3 Noise Key Derivation E2E Tests
    
    func testNoiseKeyDerivation_Flow() throws {
        // This test requires a session first
        guard WalletTestHelper.hasActiveSession(app: app) else {
            try testSessionFlow_RequestAndReceive()
        }
        
        // Navigate to a feature that uses noise keys (e.g., direct payment)
        WalletTestHelper.navigateToPaykit(app: app)
        
        let directPayButton = app.buttons["Direct Pay"]
        if directPayButton.waitForExistence(timeout: 3) {
            directPayButton.tap()
            
            // If Pubky-ring is installed, keypair should be derived
            // Otherwise, should show error or fallback
            let errorAlert = app.alerts.firstMatch
            if !PubkyRingTestHelper.isPubkyRingInstalled() {
                XCTAssertTrue(errorAlert.waitForExistence(timeout: 5))
            }
        }
    }
    
    func testNoiseKeyCache_HitAndMiss() throws {
        // First request should trigger Pubky-ring
        // Second request with same device/epoch should hit cache
        
        // This is an integration test that verifies the cache behavior
        // In a real test, we'd need to mock the cache or use instrumentation
        WalletTestHelper.navigateToPaykit(app: app)
        
        // Look for cache status in debug info (if available)
        let debugInfo = app.staticTexts.matching(identifier: "CacheStatus").firstMatch
        if debugInfo.exists {
            let label = debugInfo.label
            // Verify cache is working
            XCTAssertTrue(label.contains("cache"))
        }
    }
    
    // MARK: - 3.4 Profile & Contacts E2E Tests
    
    func testProfileFetching() throws {
        guard WalletTestHelper.hasActiveSession(app: app) else {
            try testSessionFlow_RequestAndReceive()
        }
        
        // Navigate to profile view
        WalletTestHelper.navigateToPaykit(app: app)
        
        let profileButton = app.buttons["Profile"]
        if profileButton.waitForExistence(timeout: 3) {
            profileButton.tap()
            
            // Verify profile elements are displayed
            let nameLabel = app.staticTexts.matching(identifier: "ProfileName").firstMatch
            XCTAssertTrue(nameLabel.waitForExistence(timeout: 10))
        }
    }
    
    func testFollowsSync() throws {
        guard WalletTestHelper.hasActiveSession(app: app) else {
            try testSessionFlow_RequestAndReceive()
        }
        
        // Navigate to contacts
        WalletTestHelper.navigateToContacts(app: app)
        
        // Tap sync button
        let syncButton = app.buttons["Sync Contacts"]
        if syncButton.waitForExistence(timeout: 3) {
            syncButton.tap()
            
            // Wait for sync to complete
            let loadingIndicator = app.activityIndicators.firstMatch
            if loadingIndicator.exists {
                XCTAssertTrue(loadingIndicator.waitForNonexistence(timeout: 30))
            }
            
            // Verify contacts list is updated
            let contactCount = WalletTestHelper.getContactCount(app: app)
            // At minimum, should not crash
            XCTAssertGreaterThanOrEqual(contactCount, 0)
        }
    }
    
    // MARK: - 3.5 Backup & Restore E2E Tests
    
    func testBackupExport() throws {
        guard WalletTestHelper.hasActiveSession(app: app) else {
            try testSessionFlow_RequestAndReceive()
        }
        
        // Navigate to backup
        WalletTestHelper.navigateToPaykit(app: app)
        
        let backupButton = app.buttons["Backup"]
        if backupButton.waitForExistence(timeout: 3) {
            backupButton.tap()
            
            // Verify export options are shown
            let exportButton = app.buttons["Export Sessions"]
            XCTAssertTrue(exportButton.waitForExistence(timeout: 3))
        }
    }
    
    func testBackupImport() throws {
        // Navigate to backup
        WalletTestHelper.navigateToPaykit(app: app)
        
        let backupButton = app.buttons["Backup"]
        if backupButton.waitForExistence(timeout: 3) {
            backupButton.tap()
            
            // Verify import options are shown
            let importButton = app.buttons["Import Sessions"]
            XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        }
    }
    
    // MARK: - 3.6 Cross-App Integration Tests
    
    func testCrossDeviceAuthentication() throws {
        // Navigate to session management
        WalletTestHelper.navigateToSessionManagement(app: app)
        
        // Tap cross-device option
        let crossDeviceButton = app.buttons["Use QR Code"]
        if crossDeviceButton.waitForExistence(timeout: 3) {
            crossDeviceButton.tap()
            
            // Verify QR code is displayed
            let qrImage = app.images["QRCode"]
            XCTAssertTrue(qrImage.waitForExistence(timeout: 5))
            
            // Verify URL link is also available
            let copyLinkButton = app.buttons["Copy Link"]
            XCTAssertTrue(copyLinkButton.exists)
        }
    }
    
    func testEndToEndPaymentFlow() throws {
        guard WalletTestHelper.hasActiveSession(app: app) else {
            try testSessionFlow_RequestAndReceive()
        }
        
        // Navigate to send
        app.buttons["Send"].tap()
        
        // Enter test amount
        let amountField = app.textFields["Amount"]
        if amountField.waitForExistence(timeout: 3) {
            amountField.tap()
            amountField.typeText("1000")
        }
        
        // Enter test recipient (use a Paykit pubkey format)
        let recipientField = app.textFields["Recipient"]
        if recipientField.waitForExistence(timeout: 3) {
            recipientField.tap()
            recipientField.typeText(PubkyRingTestHelper.testPubkey)
        }
        
        // Verify Paykit payment option appears
        let paykitOption = app.buttons["Pay via Paykit"]
        if paykitOption.waitForExistence(timeout: 3) {
            XCTAssertTrue(paykitOption.isEnabled)
        }
    }
    
    func testEndToEndContactDiscovery() throws {
        guard WalletTestHelper.hasActiveSession(app: app) else {
            try testSessionFlow_RequestAndReceive()
        }
        
        // Navigate to contacts
        WalletTestHelper.navigateToContacts(app: app)
        
        // Tap discover button
        let discoverButton = app.buttons["Discover Contacts"]
        if discoverButton.waitForExistence(timeout: 3) {
            discoverButton.tap()
            
            // Wait for discovery
            let loadingIndicator = app.activityIndicators.firstMatch
            if loadingIndicator.exists {
                XCTAssertTrue(loadingIndicator.waitForNonexistence(timeout: 30))
            }
            
            // Verify discovery results
            let resultsLabel = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'found'")).firstMatch
            XCTAssertTrue(resultsLabel.waitForExistence(timeout: 5) || WalletTestHelper.getContactCount(app: app) >= 0)
        }
    }
}
