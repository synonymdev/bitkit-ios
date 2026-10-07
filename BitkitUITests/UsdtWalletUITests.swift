import XCTest

final class UsdtWalletUITests: XCTestCase {
    @MainActor
    func testPaymentUsesUsdtOnLocalArbitrumFork() async throws {
        let client: String
        do {
            client = try await forkCall("web3_clientVersion", []) as? String ?? ""
        } catch {
            throw XCTSkip("Requires the local Arbitrum fork fixture in bitkit-core/tests/usdt-fork")
        }
        guard client.lowercased().contains("anvil") else { throw XCTSkip("Requires Anvil") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["USDT_RPC_URL"] = "http://127.0.0.1:18545"
        app.launchEnvironment["USDT_BUNDLER_URL"] = "http://127.0.0.1:18546"
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 3) { app.buttons["Continue"].tap() }
        if app.buttons["SkipIntro"].waitForExistence(timeout: 3) {
            app.buttons["SkipIntro"].tap()
            XCTAssertTrue(app.buttons["NewWallet"].waitForExistence(timeout: 5))
            app.buttons["NewWallet"].tap()
        }
        XCTAssertTrue(app.buttons["UsdtWallet"].waitForExistence(timeout: 90))
        capture(app, "USDT home")
        app.buttons["UsdtWallet"].tap()
        XCTAssertTrue(app.buttons["UsdtReceive"].waitForExistence(timeout: 5))
        app.buttons["UsdtReceive"].tap()
        let addressElement = app.staticTexts["UsdtReceiveAddress"]
        XCTAssertTrue(addressElement.waitForExistence(timeout: 30))
        capture(app, "USDT receive")
        app.buttons["UsdtReceiveDetails"].tap()
        capture(app, "USDT receive details")
        let address = addressElement.label
        _ = try await forkCall("test_fundWallet", [address])
        let back = app.buttons.matching(identifier: "NavigationBack")
        try XCTUnwrap(back.allElementsBoundByIndex.first(where: \.isHittable)).tap()
        let fundedBalance = app.staticTexts.matching(identifier: "UsdtBalance")
            .matching(NSPredicate(format: "label CONTAINS %@", "1000")).firstMatch
        XCTAssertTrue(fundedBalance.waitForExistence(timeout: 60))
        app.buttons["UsdtSend"].tap()
        XCTAssertTrue(app.buttons["UsdtManual"].waitForExistence(timeout: 5))
        capture(app, "USDT send options")
        app.buttons["UsdtManual"].tap()
        app.textViews["UsdtRecipient"].tap()
        app.textViews["UsdtRecipient"].typeText("0x1111111111111111111111111111111111111111")
        capture(app, "USDT recipient")
        app.buttons["UsdtRecipientContinue"].tap()
        XCTAssertTrue(app.buttons["N1"].waitForExistence(timeout: 5))
        app.buttons["N1"].tap()
        capture(app, "USDT amount")
        app.buttons["UsdtReview"].tap()
        let confirm = app.otherElements["UsdtConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 40), app.debugDescription)
        capture(app, "USDT review")
        app.buttons["UsdtReviewDetails"].tap()
        XCTAssertTrue(app.staticTexts["0x1111111111111111111111111111111111111111"].exists)
        capture(app, "USDT review details")
        let start = confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let warning = app.alerts["Are You Sure?"]
        let feeWarning = warning.staticTexts[
            "The transaction fee appears to be over 50% of the amount you are sending. Do you want to continue?"
        ]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(feeWarning.exists)
        capture(app, "USDT fee warning")
        warning.buttons["Cancel"].tap()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.images["UsdtSendSuccess"].exists)
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(feeWarning.exists)
        warning.buttons["Yes, Send"].tap()
        XCTAssertTrue(app.images["UsdtSendSuccess"].waitForExistence(timeout: 40), app.debugDescription)
        capture(app, "USDT sent")
        app.buttons["Details"].tap()
        XCTAssertTrue(app.staticTexts["Confirmed"].waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "USDT activity")
        let nativeBalance = try await forkCall("eth_getBalance", [address, "latest"]) as? String
        XCTAssertEqual(nativeBalance, "0x0")
        app.terminate()
        app.launchEnvironment["USDT_RPC_URL"] = "http://127.0.0.1:18549"
        app.launch()
        XCTAssertTrue(app.buttons["UsdtWallet"].waitForExistence(timeout: 30))
        app.buttons["UsdtWallet"].tap()
        XCTAssertTrue(app.buttons["UsdtActivity-0"].waitForExistence(timeout: 10))
        capture(app, "USDT saved activity offline after restart")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func forkCall(_ method: String, _ params: [Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18546")!)
        request.timeoutInterval = 5
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(response["result"])
    }

    @MainActor
    func testReceiveAndInvalidPaymentStaySeparateFromBitcoin() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["USDT_RPC_URL"] = "http://127.0.0.1:18545"
        app.launchEnvironment["USDT_BUNDLER_URL"] = "http://127.0.0.1:18546"
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        if app.buttons["SkipIntro"].waitForExistence(timeout: 3) {
            app.buttons["SkipIntro"].tap()
            XCTAssertTrue(app.buttons["NewWallet"].waitForExistence(timeout: 5))
            app.buttons["NewWallet"].tap()
        }
        XCTAssertTrue(app.buttons["UsdtWallet"].waitForExistence(timeout: 90), app.debugDescription)
        app.buttons["UsdtWallet"].tap()
        XCTAssertTrue(app.buttons["UsdtReceive"].waitForExistence(timeout: 5))
        app.buttons["UsdtReceive"].tap()
        XCTAssertTrue(app.staticTexts["UsdtReceiveAddress"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UsdtReceiveAddress"].label.hasPrefix("0x"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Arbitrum One only")).firstMatch.exists)
        let back = app.buttons.matching(identifier: "NavigationBack")
        try XCTUnwrap(back.allElementsBoundByIndex.first(where: \.isHittable)).tap()
        app.buttons["UsdtSend"].tap()
        XCTAssertTrue(app.buttons["UsdtManual"].waitForExistence(timeout: 5))
        app.buttons["UsdtManual"].tap()
        let recipient = app.textViews["UsdtRecipient"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.tap()
        recipient.typeText("bc1qnotanethereumaddress")
        app.buttons["UsdtRecipientContinue"].tap()
        XCTAssertTrue(app.staticTexts["UsdtError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["N1"].exists)
        recipient.tap()
        recipient.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "bc1qnotanethereumaddress".count))
        recipient
            .typeText(
                "ethereum:0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9@42161/transfer?address=0x0000000000000000000000000000000000000001&uint256=1.23e6"
            )
        app.buttons["UsdtRecipientContinue"].tap()
        XCTAssertTrue(app.buttons["N1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1.23"].exists)
        for digit in 4 ... 8 {
            app.buttons["N\(digit)"].tap()
        }
        XCTAssertTrue(app.staticTexts["1.234567"].exists)
        XCTAssertFalse(app.otherElements["UsdtConfirm"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
