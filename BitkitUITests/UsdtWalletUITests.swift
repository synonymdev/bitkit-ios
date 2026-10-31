import XCTest

final class UsdtWalletUITests: XCTestCase {
    private var rpcURL: String {
        ProcessInfo.processInfo.environment["BITKIT_TEST_USDT_RPC_URL"] ?? "http://127.0.0.1:1"
    }

    private var bundlerURL: String {
        ProcessInfo.processInfo.environment["BITKIT_TEST_USDT_BUNDLER_URL"] ?? "http://127.0.0.1:1"
    }

    private var offlineRPCURL: String {
        ProcessInfo.processInfo.environment["BITKIT_TEST_USDT_OFFLINE_RPC_URL"] ?? "http://127.0.0.1:1"
    }

    @MainActor
    func testUnknownBalanceAndManualEntryUseConsistentAmountsInCommaRegion() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "de_DE"]
        app.launchEnvironment["USDT_RPC_URL"] = "http://127.0.0.1:1"
        app.launchEnvironment["USDT_BUNDLER_URL"] = "http://127.0.0.1:1"
        app.launchEnvironment["USDT_BRIDGE_NETWORKS"] = "polygon"
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        if app.buttons["SkipIntro"].waitForExistence(timeout: 3) {
            app.buttons["SkipIntro"].tap()
            XCTAssertTrue(app.buttons["NewWallet"].waitForExistence(timeout: 5))
            app.buttons["NewWallet"].tap()
        }
        XCTAssertTrue(app.otherElements["TotalBalance-primary"].waitForExistence(timeout: 90))
        if app.buttons["UsdtIntroEnable"].waitForExistence(timeout: 10) {
            app.buttons["UsdtIntroEnable"].tap()
        }
        let homeTile = app.buttons["UsdtWallet"]
        XCTAssertTrue(homeTile.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(homeTile.label.contains("—"), homeTile.label)
        XCTAssertFalse(homeTile.label.contains("0.00"), homeTile.label)
        capture(app, "USDT unknown Home balance in German region")
        homeTile.tap()
        XCTAssertTrue(app.buttons["UsdtReceive"].waitForExistence(timeout: 5))
        let balance = app.otherElements["UsdtBalance"]
        XCTAssertTrue(balance.staticTexts["$ —"].exists, app.debugDescription)
        XCTAssertFalse(balance.staticTexts["$ 0.00"].exists)
        XCTAssertFalse(app.staticTexts["Could not update USDT. Check your connection and try again."].exists)
        XCTAssertFalse(app.staticTexts["Older activity is still syncing. Your balance is up to date when the connection is available."].exists)
        capture(app, "USDT unknown wallet in German region")
        try XCTUnwrap(app.buttons.matching(identifier: "NavigationBack").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        app.buttons["Send"].tap()
        XCTAssertTrue(app.buttons["RecipientManual"].waitForExistence(timeout: 5))
        app.buttons["RecipientManual"].tap()
        let input = app.textViews["RecipientInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let recipient = "0x18503bD685aF84E6A7bC289898bAa1C3f5d8527E"
        input.tap()
        input.typeText(recipient)
        let continueButton = app.buttons["AddressContinue"]
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: continueButton)
        wait(for: [enabled], timeout: 5)
        continueButton.tap()
        if app.buttons["UsdtEnablePromptContinue"].waitForExistence(timeout: 3) {
            app.buttons["UsdtEnablePromptContinue"].tap()
        }
        XCTAssertTrue(app.buttons["UsdtReview"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["$ 0"].exists)
        XCTAssertFalse(app.buttons["UsdtReview"].isEnabled)
        XCTAssertTrue(app.buttons["NDecimal"].label.contains("."))
        app.buttons["N1"].tap()
        app.buttons["NDecimal"].tap()
        app.buttons["N5"].tap()
        XCTAssertTrue(app.staticTexts["$ 1.5"].exists, app.debugDescription)
        capture(app, "USDT dot decimal entry in German region")
        let network = app.buttons["UsdtNetwork"]
        XCTAssertTrue(network.label.contains("Arbitrum One"))
        XCTAssertTrue(network.isEnabled)
        network.tap()
        XCTAssertTrue(app.buttons["UsdtNetwork-Polygon"].waitForExistence(timeout: 5))
        try XCTUnwrap(app.buttons.matching(identifier: "NavigationBack").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(app.buttons["UsdtReview"].waitForExistence(timeout: 5))
        try XCTUnwrap(app.buttons.matching(identifier: "NavigationBack").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        let restoredRecipient = app.textViews["RecipientInput"]
        XCTAssertTrue(restoredRecipient.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredRecipient.value as? String, recipient)
        capture(app, "Manual USDT recipient preserved")
    }

    @MainActor
    func testPaymentUsesUsdtOnLocalArbitrumFork() async throws {
        let client: String
        do {
            client = try await forkCall("web3_clientVersion", []) as? String ?? ""
        } catch {
            throw XCTSkip("Requires isolated Arbitrum fork endpoints via BITKIT_TEST_USDT_RPC_URL and BITKIT_TEST_USDT_BUNDLER_URL")
        }
        guard client.lowercased().contains("anvil") else { throw XCTSkip("Requires Anvil") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["USDT_RPC_URL"] = rpcURL
        app.launchEnvironment["USDT_BUNDLER_URL"] = bundlerURL
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        if app.buttons["SkipIntro"].waitForExistence(timeout: 3) {
            app.buttons["SkipIntro"].tap()
            XCTAssertTrue(app.buttons["NewWallet"].waitForExistence(timeout: 5))
            app.buttons["NewWallet"].tap()
        }
        XCTAssertTrue(app.otherElements["TotalBalance-primary"].waitForExistence(timeout: 90))
        if app.buttons["UsdtIntroEnable"].waitForExistence(timeout: 10) {
            app.buttons["UsdtIntroEnable"].tap()
        }
        XCTAssertTrue(app.buttons["UsdtWallet"].waitForExistence(timeout: 90))
        capture(app, "USDT home")
        app.buttons["UsdtWallet"].tap()
        XCTAssertTrue(app.buttons["UsdtReceive"].waitForExistence(timeout: 5))
        app.buttons["UsdtReceive"].tap()
        XCTAssertTrue(app.buttons["UsdtReceiveDetails"].waitForExistence(timeout: 30))
        capture(app, "USDT receive")
        app.buttons["UsdtReceiveDetails"].tap()
        let addressElement = app.otherElements["UsdtReceiveAddress"].staticTexts["ReceiveOnchainAddress"]
        XCTAssertTrue(addressElement.waitForExistence(timeout: 30))
        capture(app, "USDT receive details")
        let address = addressElement.label
        _ = try await forkCall("test_fundWallet", [address])
        let receiveHeader = app.staticTexts["Receive Dollars"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        receiveHeader.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["UsdtReceiveDetails"].waitForNonExistence(timeout: 5))
        let fundedBalance = app.otherElements["UsdtBalance"].staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "1,000")).firstMatch
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
        let reviewAddress = app.buttons["UsdtReviewAddress"]
        XCTAssertTrue(reviewAddress.waitForExistence(timeout: 5))
        XCTAssertEqual(reviewAddress.label, "0x1111111111111111111111111111111111111111")
        capture(app, "USDT review details")
        let grab = try XCTUnwrap(confirm.descendants(matching: .any).matching(identifier: "GRAB")
            .allElementsBoundByIndex.first(where: \.isHittable))
        let start = grab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: app.frame.width * 0.8, dy: 0))
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
        app.launchEnvironment["USDT_RPC_URL"] = offlineRPCURL
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
        var request = try URLRequest(url: XCTUnwrap(URL(string: bundlerURL)))
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
        app.resetAuthorizationStatus(for: .camera)
        app.launchEnvironment["USDT_RPC_URL"] = rpcURL
        app.launchEnvironment["USDT_BUNDLER_URL"] = bundlerURL
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 3) {
            app.buttons["Continue"].tap()
        }
        if app.buttons["SkipIntro"].waitForExistence(timeout: 3) {
            app.buttons["SkipIntro"].tap()
            XCTAssertTrue(app.buttons["NewWallet"].waitForExistence(timeout: 5))
            app.buttons["NewWallet"].tap()
        }
        XCTAssertTrue(app.otherElements["TotalBalance-primary"].waitForExistence(timeout: 90))
        if app.buttons["UsdtIntroEnable"].waitForExistence(timeout: 10) {
            app.buttons["UsdtIntroEnable"].tap()
        }
        XCTAssertTrue(app.buttons["UsdtWallet"].waitForExistence(timeout: 90), app.debugDescription)
        app.buttons["UsdtWallet"].tap()
        XCTAssertTrue(app.buttons["UsdtReceive"].waitForExistence(timeout: 5))
        app.buttons["UsdtReceive"].tap()
        XCTAssertTrue(app.buttons["UsdtReceiveDetails"].waitForExistence(timeout: 30))
        let qr = app.descendants(matching: .any).matching(identifier: "QRCode").firstMatch
        XCTAssertTrue(qr.waitForExistence(timeout: 5))
        let amountlessUri = qr.label
        XCTAssertFalse(amountlessUri.contains("uint256="))
        for swipingRight in [true, false] {
            let copyButton = app.buttons["ReceiveCopyQR"]
            let networkButton = app.buttons["UsdtReceiveNetwork"]
            XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
            XCTAssertTrue(networkButton.waitForExistence(timeout: 5))
            let bandTop = copyButton.frame.maxY
            let bandBottom = networkButton.frame.minY
            XCTAssertGreaterThan(bandBottom, bandTop, "Receive must leave space between the QR controls and Network")
            let y = (bandTop + bandBottom) / 2
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let left = origin.withOffset(CGVector(dx: app.frame.width * 0.2, dy: y))
            let right = origin.withOffset(CGVector(dx: app.frame.width * 0.8, dy: y))
            capture(app, "USDT Receive before blank-band swipe")
            (swipingRight ? left : right).press(forDuration: 0.05, thenDragTo: swipingRight ? right : left)
            XCTAssertTrue(app.buttons["UsdtReceiveDetails"].waitForNonExistence(timeout: 5), "Swiping the blank band must leave the USDT tab")
            XCTAssertTrue(app.staticTexts["Receive Bitcoin"].waitForExistence(timeout: 5))
            app.buttons["Tab-usdt"].tap()
            XCTAssertTrue(qr.waitForExistence(timeout: 5))
            XCTAssertEqual(qr.label, amountlessUri)
        }
        app.buttons["SpecifyInvoiceButton"].tap()
        app.buttons["N5"].tap()
        try XCTUnwrap(app.buttons.matching(identifier: "NavigationBack").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(qr.waitForExistence(timeout: 5))
        XCTAssertEqual(qr.label, amountlessUri)
        app.buttons["SpecifyInvoiceButton"].tap()
        app.buttons["N3"].tap()
        app.buttons["UsdtDepositCreate"].tap()
        XCTAssertTrue(qr.waitForExistence(timeout: 5))
        let committedUri = qr.label
        XCTAssertTrue(committedUri.contains("uint256=3000000"))
        app.buttons["SpecifyInvoiceButton"].tap()
        app.buttons["N5"].tap()
        try XCTUnwrap(app.buttons.matching(identifier: "NavigationBack").allElementsBoundByIndex.first(where: \.isHittable)).tap()
        XCTAssertTrue(qr.waitForExistence(timeout: 5))
        XCTAssertEqual(qr.label, committedUri)
        app.buttons["UsdtReceiveDetails"].tap()
        let address = app.otherElements["UsdtReceiveAddress"].staticTexts["ReceiveOnchainAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(address.label.hasPrefix("0x"))
        XCTAssertTrue(app.buttons["UsdtReceiveNetwork"].label.contains("Arbitrum One"))
        let receiveHeader = app.staticTexts["Receive Dollars"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        receiveHeader.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["UsdtReceiveDetails"].waitForNonExistence(timeout: 5))
        app.buttons["UsdtSend"].tap()
        let cameraAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "camera")).firstMatch
        XCTAssertTrue(cameraAlert.waitForExistence(timeout: 5))
        cameraAlert.buttons["Allow"].tap()
        XCTAssertTrue(cameraAlert.waitForNonExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["$ 1.23"].exists)
        for digit in 4 ... 8 {
            app.buttons["N\(digit)"].tap()
        }
        XCTAssertTrue(app.staticTexts["$ 1.234567"].exists)
        XCTAssertFalse(app.otherElements["UsdtConfirm"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
