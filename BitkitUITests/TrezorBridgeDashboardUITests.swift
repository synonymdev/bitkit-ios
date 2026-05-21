import Foundation
import UIKit
import XCTest

final class TrezorBridgeDashboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private let userEnv = TrezorUserEnvController()
    private let regtest = RegtestRpcClient()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TEST_TREZOR_EMU"] == "1", "AI-only Trezor emulator tests are disabled")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        try super.tearDownWithError()
    }

    func testBridgeConnectLifecycleAndPromptContracts() {
        launch()
        connectBridgeDevice()

        XCTAssertTrue(app.otherElements["TrezorConnectedView"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.otherElements["TrezorDeviceInfoCard"].exists)

        app.buttons["TrezorSection-DeviceInfo"].tap()
        scrollTo(app.buttons["TrezorClearCredentials"])
        app.buttons["TrezorClearCredentials"].tap()

        app.buttons["TrezorTestHook-Pin"].tap()
        XCTAssertTrue(app.otherElements["TrezorPinSheet"].waitForExistence(timeout: 5))
        app.buttons["TrezorPinCancel"].tap()

        app.buttons["TrezorTestHook-Passphrase"].tap()
        XCTAssertTrue(app.otherElements["TrezorPassphraseSheet"].waitForExistence(timeout: 5))
        app.buttons["TrezorPassphraseCancel"].tap()

        app.buttons["TrezorTestHook-Pairing"].tap()
        XCTAssertTrue(app.otherElements["TrezorPairingSheet"].waitForExistence(timeout: 5))
        app.buttons["TrezorPairingCancel"].tap()

        app.buttons["TrezorTestHook-Confirm"].tap()
        XCTAssertTrue(app.otherElements["TrezorConfirmOnDeviceOverlay"].waitForExistence(timeout: 5))
        app.buttons["TrezorConfirmOnDeviceCancel"].tap()

        app.buttons["TrezorDebugLogToggle"].tap()
        XCTAssertTrue(app.buttons["TrezorDebugLogClear"].waitForExistence(timeout: 5))
        app.buttons["TrezorDebugLogClear"].tap()

        scrollTo(app.buttons["TrezorDisconnectButton"])
        app.buttons["TrezorDisconnectButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorDeviceList"].waitForExistence(timeout: 10))

        connectBridgeDevice()
        XCTAssertTrue(app.otherElements["TrezorConnectedView"].waitForExistence(timeout: 20))
    }

    func testAddressPublicKeyMessageBalanceHistoryDetailAndSendFlow() throws {
        launch()
        connectBridgeDevice()
        app.buttons["TrezorNetwork-Regtest"].tap()

        let generatedAddresses = try generateAllAddressTypes()
        let fundingAddress = generatedAddresses["Native SegWit (P2WPKH)"] ?? generatedAddresses.values.first ?? ""
        XCTAssertTrue(fundingAddress.hasPrefix("bcrt1"), "Expected a regtest SegWit address, got \(fundingAddress)")

        try regtest.fund(address: fundingAddress, bitcoin: 0.001)
        try regtest.mineBlock()

        let xpub = try exportPublicKey()
        try signAndVerifyMessage()
        try lookupBalanceHistoryAndDetail(xpub: xpub, address: fundingAddress)

        let destinationAddress = try generateNextNativeSegwitAddress()
        try sendSignAndBroadcast(xpub: xpub, destinationAddress: destinationAddress)

        app.buttons["TrezorDebugLogToggle"].tap()
        let debugEntries = app.otherElements["TrezorDebugLogEntries"]
        XCTAssertTrue(debugEntries.waitForExistence(timeout: 5))
        let debugText = debugEntries.label.lowercased()
        XCTAssertFalse(debugText.contains("all all all all"), "Debug log must not expose the deterministic mnemonic")
        XCTAssertFalse(debugText.contains("passphrase"), "Debug log must not expose passphrase payloads")
    }

    func testBridgeUnavailableShowsRecoverableState() {
        launch(bridgeUrl: "http://127.0.0.1:1")

        let scanButton = app.buttons["TrezorScanButton"]
        if scanButton.waitForExistence(timeout: 10) {
            scanButton.tap()
        }

        let emptyState = app.otherElements["TrezorEmptyState"]
        let errorBanner = app.otherElements["TrezorDeviceListError"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10) || errorBanner.waitForExistence(timeout: 10))
    }

    private func launch(bridgeUrl: String = "http://127.0.0.1:21325") {
        app = XCUIApplication()
        app.launchEnvironment = [
            "TEST_TREZOR_EMU": "1",
            "TREZOR_BRIDGE": "true",
            "TREZOR_BRIDGE_URL": bridgeUrl,
            "TREZOR_ELECTRUM_URL": "tcp://127.0.0.1:60001",
            "E2E": "true",
            "E2E_BACKEND": "local",
            "E2E_NETWORK": "regtest",
            "GEO": "false",
        ]
        app.launch()
        XCTAssertTrue(app.otherElements["TrezorRoot"].waitForExistence(timeout: 20))
    }

    private func connectBridgeDevice() {
        if app.otherElements["TrezorConnectedView"].waitForExistence(timeout: 2) {
            return
        }

        let scanButton = app.buttons["TrezorScanButton"]
        if scanButton.waitForExistence(timeout: 10), scanButton.isHittable {
            scanButton.tap()
        }

        let bridgeDevice = app.buttons["TrezorDevice-bridge"]
        XCTAssertTrue(bridgeDevice.waitForExistence(timeout: 20))

        approveOnEmulator(for: 20)
        bridgeDevice.tap()
        XCTAssertTrue(app.otherElements["TrezorConnectedView"].waitForExistence(timeout: 30))
    }

    private func generateAllAddressTypes() throws -> [String: String] {
        app.buttons["TrezorSection-Address"].tap()

        var addresses: [String: String] = [:]
        for addressType in ["Legacy (P2PKH)", "Nested SegWit (P2SH-P2WPKH)", "Native SegWit (P2WPKH)", "Taproot (P2TR)"] {
            selectAddressType(addressType)
            approveOnEmulator(for: 10)
            app.buttons["TrezorGenerateAddress"].tap()
            let address = readStaticText("TrezorGeneratedAddress", timeout: 20)
            XCTAssertFalse(address.isEmpty)
            addresses[addressType] = address
        }

        XCTAssertTrue(addresses["Legacy (P2PKH)"]?.hasPrefix("m") == true || addresses["Legacy (P2PKH)"]?.hasPrefix("n") == true)
        XCTAssertTrue(addresses["Nested SegWit (P2SH-P2WPKH)"]?.hasPrefix("2") == true)
        XCTAssertTrue(addresses["Native SegWit (P2WPKH)"]?.hasPrefix("bcrt1q") == true)
        XCTAssertTrue(addresses["Taproot (P2TR)"]?.hasPrefix("bcrt1p") == true)
        XCTAssertTrue(app.images["TrezorGeneratedAddressQr"].exists || app.otherElements["TrezorGeneratedAddressQr"].exists)

        return addresses
    }

    private func generateNextNativeSegwitAddress() throws -> String {
        if !app.buttons["TrezorGenerateAddress"].exists {
            app.buttons["TrezorSection-Address"].tap()
        }
        selectAddressType("Native SegWit (P2WPKH)")
        app.buttons["TrezorAddressIndexIncrement"].tap()
        approveOnEmulator(for: 10)
        app.buttons["TrezorGenerateAddress"].tap()
        let address = readStaticText("TrezorGeneratedAddress", timeout: 20)
        XCTAssertTrue(address.hasPrefix("bcrt1q"))
        return address
    }

    private func selectAddressType(_ addressType: String) {
        let picker = app.buttons["TrezorAddressType"].exists ? app.buttons["TrezorAddressType"] : app.otherElements["TrezorAddressType"]
        if picker.exists {
            picker.tap()
            let option = app.buttons[addressType].exists ? app.buttons[addressType] : app.staticTexts[addressType]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
        }
    }

    private func exportPublicKey() throws -> String {
        app.buttons["TrezorSection-PublicKey"].tap()
        approveOnEmulator(for: 10)
        app.buttons["TrezorPublicKeyGet"].tap()
        let xpub = readStaticText("TrezorXpub", timeout: 20)
        XCTAssertTrue(xpub.hasPrefix("tpub") || xpub.hasPrefix("vpub") || xpub.hasPrefix("xpub") || xpub.hasPrefix("zpub"))
        XCTAssertFalse(readStaticText("TrezorPublicKeyHex", timeout: 5).isEmpty)
        return xpub
    }

    private func signAndVerifyMessage() throws {
        app.buttons["TrezorSection-SignMessage"].tap()
        clearAndType(app.textFields["TrezorMessageToSign"], text: "Bitkit Trezor emulator test")
        approveOnEmulator(for: 15)
        app.buttons["TrezorSignMessageButton"].tap()

        let signature = readStaticText("TrezorSignature", timeout: 20)
        let address = readStaticText("TrezorSignedMessageAddress", timeout: 5)
        XCTAssertFalse(signature.isEmpty)
        XCTAssertFalse(address.isEmpty)

        app.segmentedControls["TrezorSignMessageMode"].buttons["Verify"].tap()
        clearAndType(app.textFields["TrezorVerifyAddress"], text: address)
        clearAndType(app.textFields["TrezorVerifySignature"], text: signature)
        clearAndType(app.textFields["TrezorVerifyMessage"], text: "Bitkit Trezor emulator test")
        app.buttons["TrezorVerifySignatureButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorSignatureValid"].waitForExistence(timeout: 10))

        clearAndType(app.textFields["TrezorVerifyMessage"], text: "Tampered Bitkit Trezor emulator test")
        app.buttons["TrezorVerifySignatureButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorSignatureInvalid"].waitForExistence(timeout: 10))
    }

    private func lookupBalanceHistoryAndDetail(xpub: String, address: String) throws {
        app.buttons["TrezorSection-BalanceLookup"].tap()
        clearAndType(app.textFields["TrezorLookupInput"], text: address)
        app.buttons["TrezorLookupButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorAddressLookupResult"].waitForExistence(timeout: 30))

        clearAndType(app.textFields["TrezorLookupInput"], text: xpub)
        app.buttons["TrezorLookupButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorAccountResult"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.otherElements["TrezorUtxoList"].waitForExistence(timeout: 30))

        app.buttons["TrezorSection-TxHistory"].tap()
        clearAndType(app.textFields["TrezorTxHistoryInput"], text: xpub)
        app.buttons["TrezorTxHistoryButton"].tap()
        let txRow = app.otherElements["TrezorTxHistoryRow"]
        XCTAssertTrue(txRow.waitForExistence(timeout: 30))
        let txid = txRow.value as? String ?? txRow.label
        XCTAssertFalse(txid.isEmpty)

        app.buttons["TrezorSection-TxDetail"].tap()
        clearAndType(app.textFields["TrezorTxDetailXpub"], text: xpub)
        clearAndType(app.textFields["TrezorTxDetailTxid"], text: txid)
        app.buttons["TrezorTxDetailButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorTxDetailOverview"].waitForExistence(timeout: 30))
        XCTAssertFalse(readStaticText("TrezorTxDetailResultTxid", timeout: 5).isEmpty)
    }

    private func sendSignAndBroadcast(xpub: String, destinationAddress: String) throws {
        if !app.textFields["TrezorLookupInput"].exists {
            app.buttons["TrezorSection-BalanceLookup"].tap()
        }
        clearAndType(app.textFields["TrezorLookupInput"], text: xpub)
        app.buttons["TrezorLookupButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorSendSection"].waitForExistence(timeout: 30))

        scrollTo(app.textFields["TrezorSendAddress"])
        clearAndType(app.textFields["TrezorSendAddress"], text: destinationAddress)
        clearAndType(app.textFields["TrezorSendAmount"], text: "1000")
        clearAndType(app.textFields["TrezorSendFeeRate"], text: "2")
        app.buttons["TrezorComposeButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorComposeReview"].waitForExistence(timeout: 30))

        approveOnEmulator(for: 30)
        app.buttons["TrezorSignTxButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorSignedTxResult"].waitForExistence(timeout: 40))

        app.buttons["TrezorBroadcastButton"].tap()
        XCTAssertTrue(app.otherElements["TrezorBroadcastResult"].waitForExistence(timeout: 30))
        XCTAssertFalse(readStaticText("TrezorBroadcastTxid", timeout: 5).isEmpty)
    }

    private func approveOnEmulator(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        DispatchQueue.global(qos: .userInitiated).async { [userEnv] in
            while Date() < deadline {
                try? userEnv.send(type: "emulator-press-yes")
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
    }

    private func readStaticText(_ identifier: String, timeout: TimeInterval) -> String {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing static text \(identifier)")
        return element.label
    }

    private func clearAndType(_ element: XCUIElement, text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing text input \(element)")
        scrollTo(element)
        element.tap()
        if let currentValue = element.value as? String, !currentValue.isEmpty {
            element.press(forDuration: 1.0)
            app.menuItems["Select All"].tapIfExists()
            element.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        element.typeText(text)
    }

    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        guard !element.isHittable else { return }
        for _ in 0 ..< maxSwipes where !element.isHittable {
            app.swipeUp()
        }
    }
}

private final class TrezorUserEnvController {
    private let url = URL(string: "ws://127.0.0.1:9001")!
    private var nextId = 0

    func send(type: String, extra: [String: Any] = [:]) throws {
        nextId += 1
        var payload = extra
        payload["type"] = type
        payload["id"] = nextId

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        _ = try receiveString(from: task)
        try sendString(json, to: task)
        let response = try receiveString(from: task)
        let responseData = Data(response.utf8)
        guard let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              parsed["success"] as? Bool == true
        else {
            throw ControllerError.unsuccessful(response)
        }
    }

    private func sendString(_ value: String, to task: URLSessionWebSocketTask) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrown: Error?
        task.send(.string(value)) { error in
            thrown = error
            semaphore.signal()
        }
        semaphore.wait()
        if let thrown { throw thrown }
    }

    private func receiveString(from task: URLSessionWebSocketTask) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?
        task.receive { receiveResult in
            switch receiveResult {
            case let .success(.string(value)):
                result = .success(value)
            case let .success(.data(data)):
                result = .success(String(data: data, encoding: .utf8) ?? "")
            case let .failure(error):
                result = .failure(error)
            @unknown default:
                result = .failure(ControllerError.unsupportedMessage)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result?.get() ?? ""
    }

    private enum ControllerError: Error {
        case unsuccessful(String)
        case unsupportedMessage
    }
}

private final class RegtestRpcClient {
    private let url = URL(string: "http://127.0.0.1:43782")!
    private let authHeader = "Basic \(Data("polaruser:polarpass".utf8).base64EncodedString())"
    private var requestId = 0

    func fund(address: String, bitcoin: Decimal) throws {
        _ = try call(method: "sendtoaddress", params: [address, NSDecimalNumber(decimal: bitcoin).doubleValue])
    }

    func mineBlock() throws {
        let miningAddress = try call(method: "getnewaddress", params: []) as? String
        _ = try call(method: "generatetoaddress", params: [1, miningAddress ?? "bcrt1qdt5h3vzjqxhjnm3cmg8k5eqwxjc9k0cgg3vj3z"])
    }

    @discardableResult
    private func call(method: String, params: [Any]) throws -> Any? {
        requestId += 1
        let payload: [String: Any] = [
            "jsonrpc": "1.0",
            "id": requestId,
            "method": method,
            "params": params,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse, 200 ..< 300 ~= response.statusCode else {
                result = .failure(RpcError.http)
                return
            }
            result = .success(data ?? Data())
        }.resume()
        semaphore.wait()

        let data = try result?.get() ?? Data()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RpcError.invalidResponse
        }
        if let error = json["error"] as? [String: Any], !error.isEmpty {
            throw RpcError.rpc(error)
        }
        return json["result"]
    }

    private enum RpcError: Error {
        case http
        case invalidResponse
        case rpc([String: Any])
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if waitForExistence(timeout: 2), isHittable {
            tap()
        }
    }
}
