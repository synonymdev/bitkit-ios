//
//  ProfileCreationTest.swift
//  BitkitUITests
//
//  Test profile creation with invite code
//

import XCTest

final class ProfileCreationTest: XCTestCase {
    
    let app = XCUIApplication()
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }
    
    override func tearDownWithError() throws {
        // Clean up if needed
    }
    
    /// Test creating a new Pubky identity with invite code
    func testCreateProfileWithInviteCode() throws {
        // Wait for app to load
        let yourNameButton = app.staticTexts["Your Name"]
        XCTAssertTrue(yourNameButton.waitForExistence(timeout: 10), "Home screen should load")
        
        // Tap on "Your Name" to go to profile
        yourNameButton.tap()
        
        // Wait for profile screen
        let createProfileTitle = app.staticTexts["Create Profile"]
        let editProfileTitle = app.staticTexts["Edit Profile"]
        
        // Check if we need to create profile or already have one
        if createProfileTitle.waitForExistence(timeout: 5) {
            // Need to create profile
            
            // Look for invite code field
            let inviteCodeField = app.textFields["XXXX-XXXX-XXXX"]
            if inviteCodeField.waitForExistence(timeout: 3) {
                inviteCodeField.tap()
                inviteCodeField.typeText("0Z4G-DVGW-JY10")
            }
            
            // Tap "Create New Pubky Identity"
            let createButton = app.buttons["Create New Pubky Identity"]
            XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Create button should exist")
            createButton.tap()
            
            // Wait for identity creation
            sleep(10)
            
            // Verify we're now on Edit Profile screen
            XCTAssertTrue(editProfileTitle.waitForExistence(timeout: 15), "Should navigate to Edit Profile after creation")
            
            // Verify Pubky ID is shown
            let pubkyIdLabel = app.staticTexts["Your Pubky ID"]
            XCTAssertTrue(pubkyIdLabel.exists, "Pubky ID label should be visible")
            
        } else if editProfileTitle.waitForExistence(timeout: 5) {
            // Already have a profile - just verify it works
            let pubkyIdLabel = app.staticTexts["Your Pubky ID"]
            XCTAssertTrue(pubkyIdLabel.exists, "Pubky ID label should be visible")
        } else {
            XCTFail("Neither Create Profile nor Edit Profile screen appeared")
        }
    }
    
    /// Test profile editing
    func testEditProfile() throws {
        // Navigate to profile
        let yourNameButton = app.staticTexts["Your Name"]
        XCTAssertTrue(yourNameButton.waitForExistence(timeout: 10))
        yourNameButton.tap()
        
        // Wait for edit screen
        let editProfileTitle = app.staticTexts["Edit Profile"]
        guard editProfileTitle.waitForExistence(timeout: 10) else {
            // May need to create profile first
            return
        }
        
        // Find and edit name field
        let nameField = app.textFields["Enter your name"]
        if nameField.exists {
            nameField.tap()
            nameField.clearAndEnterText("Test User 2")
        }
        
        // Find and edit bio field
        let bioField = app.textFields["Tell people about yourself"]
        if bioField.exists {
            bioField.tap()
            bioField.clearAndEnterText("iOS Test User for Paykit E2E")
        }
        
        // Tap Publish Profile
        let publishButton = app.buttons["Publish Profile"]
        if publishButton.exists && publishButton.isEnabled {
            publishButton.tap()
            
            // Wait for success
            let successMessage = app.staticTexts["Profile published successfully!"]
            XCTAssertTrue(successMessage.waitForExistence(timeout: 10), "Should show success message")
        }
    }
}

// Helper extension
extension XCUIElement {
    func clearAndEnterText(_ text: String) {
        guard let stringValue = self.value as? String else {
            self.typeText(text)
            return
        }
        
        // Select all and delete
        self.tap()
        if !stringValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count)
            self.typeText(deleteString)
        }
        self.typeText(text)
    }
}

