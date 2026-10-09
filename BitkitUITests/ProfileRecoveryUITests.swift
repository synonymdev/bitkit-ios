import XCTest

final class ProfileRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-profile-recovery-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        try super.tearDownWithError()
    }

    func testProfileControlsStayReadOnlyUntilSessionAndProfileRecover() {
        XCTAssertTrue(app.staticTexts["ProfileViewName"].waitForExistence(timeout: 10))
        assertReadOnlyControls()

        for id in ["ProfileCopy", "ProfileQRCode"] {
            scrollToTop()
            app.buttons["ProfileFixtureResetClipboard"].tap()
            let copy = app.buttons[id]
            XCTAssertTrue(copy.isEnabled)
            copy.tap()
            app.buttons["ProfileFixtureClipboard"].tap()
            XCTAssertEqual(app.staticTexts["ProfileFixtureClipboardValue"].label, "profile-recovery-fixture")
            let popup = app.descendants(matching: .any)["ProfilePubkyCopiedToast"].firstMatch
            XCTAssertTrue(popup.exists)
            popup.tap()
        }

        scrollToBottom()
        app.buttons["ProfileSignOut"].tap()
        app.alerts.buttons["Disconnect"].tap()
        waitForStatus("Disconnecting")
        XCTAssertTrue(app.staticTexts["ProfileViewName"].exists)
        app.buttons["ProfileFixtureFail"].tap()
        waitForStatus("Idle")
        XCTAssertTrue(app.staticTexts["ProfileViewName"].exists)
        let errorToast = app.staticTexts["Disconnect Profile"]
        XCTAssertTrue(errorToast.waitForExistence(timeout: 5))
        XCTAssertTrue(errorToast.waitForNonExistence(timeout: 10))

        app.buttons["ProfileFixtureRestore"].tap()
        XCTAssertEqual(app.buttons["ProfileFixtureRestore"].value as? String, "Restored")
        assertReadOnlyControls()

        for outcome in ["ProfileFixtureFail", "ProfileFixtureLoad"] {
            scrollToBottom()
            let retry = app.buttons["ProfileRetry"]
            XCTAssertTrue(retry.isEnabled)
            retry.tap()
            waitForStatus("Loading")
            XCTAssertFalse(retry.isEnabled)
            assertReadOnlyControls()
            app.buttons[outcome].tap()
            waitForStatus("Idle")
        }

        XCTAssertTrue(app.buttons["ProfileRetry"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ProfileSignOut"].exists)
        XCTAssertTrue(app.buttons["ProfileAddTag"].isEnabled)
        XCTAssertTrue(app.buttons["Tag-public-tag-delete"].exists)
        scrollToTop()
        let edit = app.buttons["ProfileEdit"]
        XCTAssertTrue(edit.isEnabled)
        edit.tap()
        XCTAssertTrue(app.staticTexts["ProfileFixtureEditing"].waitForExistence(timeout: 5))
    }

    private func assertReadOnlyControls() {
        scrollToTop()
        let edit = app.buttons["ProfileEdit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(edit.isEnabled)
        edit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.staticTexts["ProfileFixtureEditing"].exists)
        scrollToBottom()
        let addTag = app.buttons["ProfileAddTag"]
        XCTAssertTrue(addTag.exists)
        XCTAssertFalse(addTag.isEnabled)
        addTag.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(app.textFields["AddTagInput"].exists)
        XCTAssertFalse(app.buttons["Tag-public-tag-delete"].exists)
    }

    private func waitForStatus(_ value: String) {
        let status = app.staticTexts["ProfileFixtureStatus"]
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed)
    }

    private func scrollToTop() {
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
    }

    private func scrollToBottom() {
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
    }
}
