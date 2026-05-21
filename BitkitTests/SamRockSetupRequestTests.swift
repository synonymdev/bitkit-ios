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
    }

    func testAllowsLocalHttpSetupUrl() {
        let localhost = SamRockSetupRequest.parse("http://localhost/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
        let loopback = SamRockSetupRequest.parse("http://127.0.0.1:23000/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
        let privateNetwork = SamRockSetupRequest.parse("http://192.168.1.10/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")

        XCTAssertEqual(localhost?.requestsBitcoinOnchain, true)
        XCTAssertEqual(loopback?.requestsBitcoinOnchain, true)
        XCTAssertEqual(privateNetwork?.requestsBitcoinOnchain, true)
    }

    func testRejectsNonSamRockUrls() {
        XCTAssertNil(SamRockSetupRequest.parse("bitcoin:bc1qexample"))
        XCTAssertNil(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/other/protocol?otp=abc123"))
        XCTAssertNil(SamRockSetupRequest.parse("https://btcpay.example/plugins/store123/samrock/protocol"))
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
}

private extension SamRockSetupRequestTests {
    static let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
}
