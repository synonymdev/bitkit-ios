import XCTest

final class ContactImportUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-contact-import-ui-test"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
        try super.tearDownWithError()
    }

    func testOverviewBlocksSelectAndRepeatedImportUntilSaveCompletes() {
        let select = app.buttons["ContactImportOverviewSelect"]
        let importAll = app.buttons["ContactImportOverviewImportAll"]
        XCTAssertTrue(importAll.waitForExistence(timeout: 10))
        XCTAssertTrue(select.isEnabled)
        XCTAssertTrue(importAll.isEnabled)

        importAll.tap()
        waitForPendingSave()
        XCTAssertFalse(select.isEnabled)
        XCTAssertFalse(importAll.isEnabled)
        select.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        importAll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        importAll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertPendingImport()
        XCTAssertTrue(select.exists)
        XCTAssertFalse(app.buttons["ContactImportSelectContinue"].exists)

        finishSave(expectedKeys: "pubky-alice,pubky-bob", expectedSaves: 2)
    }

    func testSelectionBlocksRepeatedImportUntilSaveCompletes() {
        let select = app.buttons["ContactImportOverviewSelect"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        let continueButton = app.buttons["ContactImportSelectContinue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        app.buttons["ContactImportSelect_pubky-bob"].tap()
        XCTAssertTrue(continueButton.isEnabled)

        continueButton.tap()
        waitForPendingSave()
        XCTAssertFalse(continueButton.isEnabled)
        continueButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        continueButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertPendingImport()

        finishSave(expectedKeys: "pubky-alice", expectedSaves: 1)
    }

    private func waitForPendingSave() {
        let finish = app.buttons["ContactImportFixtureFinishSave"]
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: finish)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 5), .completed)
    }

    private func assertPendingImport() {
        XCTAssertEqual(app.staticTexts["ContactImportFixtureCounts"].label, "Imports: 1, saves: 0")
        XCTAssertEqual(app.staticTexts["ContactImportFixturePreview"].label, "Preview retained")
        XCTAssertFalse(app.staticTexts["ContactImportFixtureCompleted"].exists)
    }

    private func finishSave(expectedKeys: String, expectedSaves: Int) {
        app.buttons["ContactImportFixtureFinishSave"].tap()
        let completed = app.staticTexts["ContactImportFixtureCompleted"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertEqual(completed.label, expectedKeys)
        XCTAssertEqual(app.staticTexts["ContactImportFixtureCounts"].label, "Imports: 1, saves: \(expectedSaves)")
        XCTAssertEqual(app.staticTexts["ContactImportFixturePreview"].label, "Preview cleared")
    }
}
