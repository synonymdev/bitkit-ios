@testable import Bitkit
import BitkitCore
import XCTest

final class SamRockSetupRequestTests: XCTestCase {
    func testParsesModernSamRockSetupUrl() throws {
        let setup = SamRockSetupRequest.parse(
            "https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain%2Cliquid-chain%2Cbtc-ln&otp=abc123"
        )

        XCTAssertEqual(setup?.storeId, "store123")
        XCTAssertEqual(setup?.otp, "abc123")
        XCTAssertEqual(setup?.hostDisplayName, "btcpay.example")
        let postURL = try XCTUnwrap(setup?.postURL)
        let postQueryItems = URLComponents(url: postURL, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(postQueryItems, [
            URLQueryItem(name: "setup", value: "btc-chain,liquid-chain,btc-ln"),
            URLQueryItem(name: "otp", value: "abc123"),
        ])
        XCTAssertEqual(setup?.requestsBitcoinOnchain, true)
        XCTAssertEqual(setup?.requestsUnsupportedMethods, true)
    }

    func testParsesLightningWrappedSamRockSetupUrl() throws {
        let setup = try XCTUnwrap(SamRockSetupRequest.parse(
            "lightning:https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"
        ))

        XCTAssertEqual(setup.storeId, "store123")
        XCTAssertEqual(setup.otp, "abc123")
        XCTAssertEqual(setup.hostDisplayName, "btcpay.example")
        XCTAssertEqual(setup.postURL.absoluteString, "https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
    }

    func testParsesSamRockSetupUrlWithBasePath() throws {
        let setup = try XCTUnwrap(SamRockSetupRequest.parse(
            "https://btcpay.example/btcpay/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"
        ))

        XCTAssertEqual(setup.storeId, "store123")
        XCTAssertEqual(setup.hostDisplayName, "btcpay.example")
        XCTAssertEqual(setup.postURL.absoluteString, "https://btcpay.example/btcpay/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
        XCTAssertTrue(SamRockSetupRequest.isProtocolURL("https://btcpay.example/btcpay/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))
    }

    func testDefaultsMissingSetupToAllSupportedMethods() {
        let setup = SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?otp=abc123")

        XCTAssertEqual(setup?.requestsBitcoinOnchain, true)
        XCTAssertEqual(setup?.requestsUnsupportedMethods, true)
    }

    func testPostUrlKeepsOnlyOtpWhenSetupIsMissing() throws {
        let setup = try XCTUnwrap(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?otp=abc123"))

        let postQueryItems = URLComponents(url: setup.postURL, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(postQueryItems, [
            URLQueryItem(name: "otp", value: "abc123"),
        ])
    }

    func testLightningOnlySetupDoesNotRequestBitcoinOnchain() {
        let setup = SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-ln&otp=abc123")

        XCTAssertEqual(setup?.requestsBitcoinOnchain, false)
        XCTAssertEqual(setup?.requestsUnsupportedMethods, true)
    }

    func testUnknownSetupMethodsDoNotDefaultToBitcoinOnchain() {
        let setup = SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?setup=unknown&otp=abc123")

        XCTAssertEqual(setup?.requestsBitcoinOnchain, false)
        XCTAssertEqual(setup?.requestsUnsupportedMethods, true)
    }

    func testUnknownSetupMethodsKeepLimitedSupportWarningWithBitcoinOnchain() {
        let setup = SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain,new-method&otp=abc123")

        XCTAssertEqual(setup?.requestsBitcoinOnchain, true)
        XCTAssertEqual(setup?.requestsUnsupportedMethods, true)
    }

    func testRejectsPublicHttpSetupUrl() {
        XCTAssertNil(SamRockSetupRequest.parse("http://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))
        XCTAssertTrue(SamRockSetupRequest
            .isPublicHTTPProtocolURL("http://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))
        XCTAssertTrue(SamRockSetupRequest
            .isPublicHTTPProtocolURL("lightning:http://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))
    }

    func testAllowsLocalHttpSetupUrl() {
        let localhost = SamRockSetupRequest.parse("http://localhost/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
        let loopback = SamRockSetupRequest.parse("http://127.0.0.1:23000/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
        let privateNetwork = SamRockSetupRequest.parse("http://192.168.1.10/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")

        XCTAssertEqual(localhost?.requestsBitcoinOnchain, true)
        XCTAssertEqual(loopback?.requestsBitcoinOnchain, true)
        XCTAssertEqual(privateNetwork?.requestsBitcoinOnchain, true)
    }

    func testRejectsSetupUrlWithUserInfo() {
        XCTAssertNil(SamRockSetupRequest.parse("https://user:pass@btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))
    }

    func testSanitizedDescriptionStripsSensitiveSetupValues() {
        XCTAssertEqual(
            SamRockSetupRequest.sanitizedDescription("https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=secret#frag"),
            "https://btcpay.example/plugins/store123/samrock/protocol"
        )
        XCTAssertEqual(
            SamRockSetupRequest.sanitizedDescription("lightning:https://btcpay.example/plugins/store123/samrock/protocol?otp=secret"),
            "https://btcpay.example/plugins/store123/samrock/protocol"
        )
        XCTAssertEqual(
            SamRockSetupRequest.sanitizedDescription("https://user:pass@btcpay.example/plugins/store123/samrock/protocol?otp=secret"),
            "https://btcpay.example/plugins/store123/samrock/protocol"
        )
        XCTAssertEqual(
            SamRockSetupRequest.sanitizedDescription("https://btcpay.example/plugins/%zz/samrock/protocol?otp=secret"),
            "https://btcpay.example/plugins/%zz/samrock/protocol"
        )
        XCTAssertNil(SamRockSetupRequest.sanitizedDescription("bitcoin:bc1qexample?amount=1"))
    }

    func testRejectsNonSamRockUrls() {
        XCTAssertNil(SamRockSetupRequest.parse("bitcoin:bc1qexample"))
        XCTAssertNil(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/other/protocol?otp=abc123"))
        XCTAssertNil(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol"))
        XCTAssertNil(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol/extra?otp=abc123"))
    }

    func testMapsSelectedAddressTypeToDescriptorAccountType() {
        XCTAssertEqual(SamRockService.accountType(forSelectedAddressType: "legacy"), .legacy)
        XCTAssertEqual(SamRockService.accountType(forSelectedAddressType: "nestedSegwit"), .wrappedSegwit)
        XCTAssertEqual(SamRockService.accountType(forSelectedAddressType: "nativeSegwit"), .nativeSegwit)
        XCTAssertEqual(SamRockService.accountType(forSelectedAddressType: "taproot"), .taproot)
        XCTAssertEqual(SamRockService.accountType(forSelectedAddressType: nil), .nativeSegwit)
        XCTAssertEqual(SamRockService.accountType(forSelectedAddressType: "unknown"), .nativeSegwit)
    }

    func testNativeSegwitDescriptorShape() throws {
        let descriptor = try BitkitCore.deriveOnchainDescriptor(
            mnemonicPhrase: Self.testMnemonic,
            network: .bitcoin,
            bip39Passphrase: nil,
            accountType: .nativeSegwit,
            accountIndex: 0
        )

        XCTAssertTrue(descriptor.hasPrefix("wpkh(["))
        XCTAssertTrue(descriptor.contains("/84'/0'/0']xpub"))
        XCTAssertTrue(descriptor.hasSuffix("/0/*)"))
    }

    func testNativeSegwitDescriptorUsesTestCoinTypeForNonBitcoinNetworks() throws {
        let descriptor = try BitkitCore.deriveOnchainDescriptor(
            mnemonicPhrase: Self.testMnemonic,
            network: .regtest,
            bip39Passphrase: nil,
            accountType: .nativeSegwit,
            accountIndex: 0
        )

        XCTAssertTrue(descriptor.contains("/84'/1'/0']xpub"))
    }

    func testDecodesLowercaseSamRockResponse() throws {
        let data = Data("""
        {
          "success": true,
          "message": "Wallet setup successfully.",
          "result": {
            "results": {
              "BTC": { "success": true, "message": null }
            }
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(SamRockResponseEnvelope.self, from: data)

        XCTAssertEqual(response.success, true)
        XCTAssertEqual(response.message, "Wallet setup successfully.")
        XCTAssertEqual(response.result?.results?["BTC"]?.success, true)
    }

    func testDecodesUppercaseSamRockResponse() throws {
        let data = Data("""
        {
          "Success": true,
          "Message": "Wallet setup successfully.",
          "Result": {
            "Results": {
              "BTC": { "Success": true, "Message": null }
            }
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(SamRockResponseEnvelope.self, from: data)

        XCTAssertEqual(response.success, true)
        XCTAssertEqual(response.message, "Wallet setup successfully.")
        XCTAssertEqual(response.result?.results?["BTC"]?.success, true)
    }

    func testRegisterTreatsMalformedSuccessBodyAsInvalidResponse() async throws {
        let service = try makeServiceReturning(statusCode: 200, body: "<html></html>")
        let setup = try XCTUnwrap(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))

        await assertThrowsAppError({
            try await service.registerBitcoinOnchain(setup, walletIndex: Self.testWalletIndex)
        }, t("btcpay__invalid_response"))
    }

    func testRegisterWrapsTransportError() async throws {
        let service = try makeServiceThrowing(URLError(.notConnectedToInternet))
        let setup = try XCTUnwrap(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))

        await assertThrowsAppError({
            try await service.registerBitcoinOnchain(setup, walletIndex: Self.testWalletIndex)
        }, t("btcpay__request_error"))
    }

    func testRegisterPostsDescriptorFormPayload() async throws {
        try prepareWalletKeychain()
        let setup = try XCTUnwrap(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123"))
        var capturedRequest: URLRequest?
        SamRockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("""{"Success":true,"Result":{"Results":{"BTC":{"Success":true}}}}""".utf8))
        }

        try await SamRockService(urlSession: samRockURLSession()).registerBitcoinOnchain(setup, walletIndex: Self.testWalletIndex)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")

        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.hasPrefix("json="))
        let json = try XCTUnwrap(String(body.dropFirst("json=".count)).removingPercentEncoding)
        XCTAssertFalse(json.contains("Version"))
        XCTAssertTrue(json.contains(#""BTC""#))
        XCTAssertTrue(json.contains(#""Descriptor""#))
        XCTAssertTrue(json.contains("wpkh(["))
    }
}

private extension SamRockSetupRequestTests {
    static let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let testWalletIndex = 99

    func makeServiceReturning(statusCode: Int, body: String) throws -> SamRockService {
        try prepareWalletKeychain()
        SamRockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }

        return SamRockService(urlSession: samRockURLSession())
    }

    func makeServiceThrowing(_ error: Error) throws -> SamRockService {
        try prepareWalletKeychain()
        SamRockURLProtocol.handler = { _ in throw error }

        return SamRockService(urlSession: samRockURLSession())
    }

    func prepareWalletKeychain() throws {
        try? Keychain.delete(key: .bip39Mnemonic(index: Self.testWalletIndex))
        try? Keychain.delete(key: .bip39Passphrase(index: Self.testWalletIndex))
        try Keychain.saveString(key: .bip39Mnemonic(index: Self.testWalletIndex), str: Self.testMnemonic)
        UserDefaults.standard.removeObject(forKey: "selectedAddressType")
    }

    func samRockURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SamRockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func assertThrowsAppError(
        _ operation: () async throws -> Void,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected AppError", file: file, line: line)
        } catch let error as AppError {
            XCTAssertEqual(error.message, message, file: file, line: line)
        } catch {
            XCTFail("Expected AppError, got \(error)", file: file, line: line)
        }
    }
}

private final class SamRockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
