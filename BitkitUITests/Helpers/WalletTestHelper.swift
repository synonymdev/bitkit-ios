//
//  WalletTestHelper.swift
//  BitkitUITests
//
//  Test helper for wallet operations in E2E tests
//

import XCTest

/// Helper for wallet operations in E2E tests
class WalletTestHelper {
    
    // MARK: - Navigation
    
    /// Navigate to the Paykit section
    static func navigateToPaykit(app: XCUIApplication) {
        // Tap on Settings tab
        let settingsTab = app.tabBars.buttons["Settings"]
        if settingsTab.exists {
            settingsTab.tap()
        }
        
        // Look for Paykit menu item
        let paykitButton = app.buttons["Paykit"]
        if paykitButton.waitForExistence(timeout: 3) {
            paykitButton.tap()
        }
    }
    
    /// Navigate to Contacts
    static func navigateToContacts(app: XCUIApplication) {
        navigateToPaykit(app: app)
        
        let contactsButton = app.buttons["Contacts"]
        if contactsButton.waitForExistence(timeout: 3) {
            contactsButton.tap()
        }
    }
    
    /// Navigate to Session Management
    static func navigateToSessionManagement(app: XCUIApplication) {
        navigateToPaykit(app: app)
        
        let sessionsButton = app.buttons["Sessions"]
        if sessionsButton.waitForExistence(timeout: 3) {
            sessionsButton.tap()
        }
    }
    
    // MARK: - Wallet State
    
    /// Check if wallet is initialized
    static func isWalletInitialized(app: XCUIApplication) -> Bool {
        // Look for main wallet UI elements
        return app.staticTexts["Balance"].exists ||
               app.buttons["Send"].exists ||
               app.buttons["Receive"].exists
    }
    
    /// Wait for wallet to be ready
    static func waitForWalletReady(
        app: XCUIApplication,
        timeout: TimeInterval = 30
    ) -> Bool {
        let sendButton = app.buttons["Send"]
        return sendButton.waitForExistence(timeout: timeout)
    }
    
    // MARK: - Session Verification
    
    /// Check if a session is active
    static func hasActiveSession(app: XCUIApplication) -> Bool {
        navigateToSessionManagement(app: app)
        
        // Look for session indicators
        let noSessionsText = app.staticTexts["No active sessions"]
        return !noSessionsText.exists
    }
    
    /// Get the number of active sessions
    static func getActiveSessionCount(app: XCUIApplication) -> Int {
        navigateToSessionManagement(app: app)
        
        // Count session cells
        return app.cells.matching(identifier: "SessionCell").count
    }
    
    // MARK: - Contact Verification
    
    /// Get the number of contacts
    static func getContactCount(app: XCUIApplication) -> Int {
        navigateToContacts(app: app)
        
        // Count contact cells
        return app.cells.matching(identifier: "ContactCell").count
    }
    
    /// Check if a specific contact exists
    static func hasContact(app: XCUIApplication, name: String) -> Bool {
        navigateToContacts(app: app)
        
        return app.staticTexts[name].exists
    }
    
    // MARK: - Payment Flow
    
    /// Initiate a payment
    static func initiatePayment(
        app: XCUIApplication,
        amount: String,
        recipient: String
    ) {
        // Tap Send button
        app.buttons["Send"].tap()
        
        // Enter amount
        let amountField = app.textFields["Amount"]
        if amountField.waitForExistence(timeout: 3) {
            amountField.tap()
            amountField.typeText(amount)
        }
        
        // Enter recipient
        let recipientField = app.textFields["Recipient"]
        if recipientField.waitForExistence(timeout: 3) {
            recipientField.tap()
            recipientField.typeText(recipient)
        }
    }
    
    // MARK: - UI Assertions
    
    /// Assert that an element contains text
    static func assertContainsText(
        app: XCUIApplication,
        text: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.staticTexts.containing(predicate).firstMatch
        return element.waitForExistence(timeout: timeout)
    }
    
    /// Assert that an alert is shown
    static func assertAlertShown(
        app: XCUIApplication,
        title: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let alert = app.alerts[title]
        return alert.waitForExistence(timeout: timeout)
    }
    
    /// Dismiss any alerts
    static func dismissAlerts(app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        if alert.exists {
            if alert.buttons["OK"].exists {
                alert.buttons["OK"].tap()
            } else if alert.buttons["Cancel"].exists {
                alert.buttons["Cancel"].tap()
            }
        }
    }
}

