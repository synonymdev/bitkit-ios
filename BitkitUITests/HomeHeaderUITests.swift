import XCTest

final class HomeHeaderUITests: XCTestCase {
    /// Points 20pt below a button's centre sit inside the 48pt header row but outside the 32pt icon frame.
    private let belowIconCentre: CGFloat = 20

    @MainActor
    func testHeaderRowTapsOpenHeaderButtonsAndBalanceStillToggles() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-appUpdateIgnoreTimestamp", String(Date().timeIntervalSince1970)]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        if app.buttons["SkipIntro"].waitForExistence(timeout: 3) {
            app.buttons["SkipIntro"].tap()
            XCTAssertTrue(app.buttons["NewWallet"].waitForExistence(timeout: 5))
            app.buttons["NewWallet"].tap()
        }
        let balance = app.otherElements["TotalBalance-primary"]
        XCTAssertTrue(balance.waitForExistence(timeout: 90))
        if app.buttons["UsdtIntroEnable"].waitForExistence(timeout: 10) {
            app.buttons["UsdtIntroEnable"].tap()
            XCTAssertTrue(app.buttons["UsdtIntroEnable"].waitForNonExistence(timeout: 5))
        }

        let menu = app.buttons["HeaderMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        tap(app, at: CGPoint(x: menu.frame.midX, y: menu.frame.midY + belowIconCentre))
        let drawerSettings = app.buttons["DrawerSettings"]
        XCTAssertTrue(drawerSettings.waitForExistence(timeout: 5), app.debugDescription)
        tap(app, at: CGPoint(x: 40, y: app.frame.midY))
        XCTAssertTrue(drawerSettings.waitForNonExistence(timeout: 5))

        let profile = app.buttons["ProfileButton"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        let back = app.buttons.matching(identifier: "NavigationBack").firstMatch
        // The profile button navigates only once Pubky has initialized, which can lag on a fresh wallet.
        for _ in 0 ..< 6 where !back.exists {
            tap(app, at: CGPoint(x: profile.frame.midX, y: profile.frame.midY + belowIconCentre))
            _ = back.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(back.exists, app.debugDescription)
        try XCTUnwrap(app.buttons.matching(identifier: "NavigationBack").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(balance.waitForExistence(timeout: 5))

        let symbol = balance.staticTexts["MoneyFiatSymbol"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 5))
        let unitBefore = symbol.label
        balance.tap()
        let toggled = expectation(for: NSPredicate(format: "label != %@", unitBefore), evaluatedWith: balance.staticTexts["MoneyFiatSymbol"])
        wait(for: [toggled], timeout: 5)
        balance.tap()
        let restored = expectation(for: NSPredicate(format: "label == %@", unitBefore), evaluatedWith: balance.staticTexts["MoneyFiatSymbol"])
        wait(for: [restored], timeout: 5)
    }

    @MainActor
    private func tap(_ app: XCUIApplication, at point: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }
}
