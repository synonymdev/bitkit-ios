import XCTest

final class ContactsRetryUITests: XCTestCase {
    func testEmptyLoadErrorShowsInlineRetryAndRecovers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-contacts-retry-ui-test"]
        app.launch()
        defer { app.terminate() }

        let retry = app.buttons["ContactsRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Contacts unavailable"].exists)
        attach(app, name: "Contacts inline error before Retry")
        retry.tap()
        XCTAssertTrue(app.staticTexts["Recovered contact"].waitForExistence(timeout: 5))
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(app.staticTexts["Contacts unavailable"].exists)
        attach(app, name: "Contacts recovered after Retry")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
