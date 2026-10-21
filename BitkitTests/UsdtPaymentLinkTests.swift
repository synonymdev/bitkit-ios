@testable import Bitkit
import Combine
import XCTest

final class UsdtPaymentLinkTests: XCTestCase {
    private let recipient = "0x18503bD685aF84E6A7bC289898bAa1C3f5d8527E"
    private var uri: String {
        "ethereum:\(PaykitUsdt.token)@42161/transfer?address=\(recipient)"
    }

    func testPaymentLinkPreservesOptionalAtomicAmount() throws {
        XCTAssertEqual(try resolveUsdtPaymentRoute(input: uri, isEnabled: true), .usdtPayment(recipient: recipient, amount: ""))
        XCTAssertEqual(try resolveUsdtPaymentRoute(input: " \(uri)&uint256=10001\n", isEnabled: true),
                       .usdtPayment(recipient: recipient, amount: "0.010001"))
        XCTAssertEqual(try resolveUsdtPaymentRoute(input: uri.replacingOccurrences(of: "ethereum:", with: "ETHEREUM:"), isEnabled: true),
                       .usdtPayment(recipient: recipient, amount: ""))
    }

    func testBareEvmAddressOpensUsdtWithoutAnAmount() throws {
        for input in [recipient, recipient.lowercased(), " \(recipient)\n"] {
            XCTAssertEqual(try resolveUsdtPaymentRoute(input: input, isEnabled: true),
                           .usdtPayment(recipient: recipient, amount: ""))
        }
        for input in ["0x1234", "0x" + String(repeating: "g", count: 40), PaykitUsdt.token] {
            XCTAssertThrowsError(try resolveUsdtPaymentRoute(input: input, isEnabled: true), input)
        }
        XCTAssertThrowsError(try resolveUsdtPaymentRoute(input: recipient, isEnabled: false))
    }

    @MainActor
    func testExplicitUsdtInputKeepsItsPaymentWhenOptInIsDisabled() async throws {
        snapshotAppDefaults(UsdtPreference.key)
        UserDefaults.standard.set(UsdtPreference.disabled.rawValue, forKey: UsdtPreference.key)
        XCTAssertFalse(UsdtPreference.isEnabled())
        for (input, amount) in [(uri + "&uint256=10001", "0.010001"), (recipient, "")] {
            XCTAssertEqual(try resolveUsdtPaymentRoute(input: input, isEnabled: true),
                           .usdtPayment(recipient: recipient, amount: amount))
            for enabled in [false, true] {
                let clipboardSupported = await ClipboardPromptValidator.isSupportedURI(
                    input, ownPublicKey: nil, contacts: [], isUsdtEnabled: enabled
                ) { _ in
                    XCTFail("USDT clipboard inputs must be validated locally")
                    return false
                }
                XCTAssertEqual(clipboardSupported, enabled)
            }
        }
    }

    func testUnsupportedPaymentLinksCannotOpenTheWallet() {
        for input in [
            uri.replacingOccurrences(of: "@42161", with: "@1"),
            uri.replacingOccurrences(of: PaykitUsdt.token, with: recipient),
            uri + "&uint256=1&uint256=2",
            uri + "&uint256=-1",
            uri + "&unknown=1",
        ] {
            XCTAssertThrowsError(try resolveUsdtPaymentRoute(input: input, isEnabled: true), input)
        }
        XCTAssertThrowsError(try resolveUsdtPaymentRoute(input: uri, isEnabled: false))
    }

    @MainActor
    func testManualEntryValidatesUsdtNetworkAndWalletScope() async {
        let app = AppViewModel()
        defer { ToastWindowManager.shared.hideToast() }
        let cases: [(String, ScanHandlingScope, ManualEntryValidationResult)] = [
            (uri + "&uint256=10001", .unrestricted, .valid),
            (uri + "&uint256=10001", .onchainPayments, .onchainOnly),
            (recipient, .unrestricted, .valid),
            (recipient, .onchainPayments, .onchainOnly),
            ("0x1234", .unrestricted, .invalid),
            (uri.replacingOccurrences(of: "@42161", with: "@1"), .unrestricted, .invalid),
            (uri, .unrestricted, .valid),
        ]
        for (input, scope, result) in cases {
            let validated = expectation(description: "Manual entry validated")
            let observation = app.$isManualEntryInputValid.dropFirst().sink { actual in
                XCTAssertEqual(actual, result == .valid)
                validated.fulfill()
            }
            app.validateManualEntryInput(input, savingsBalanceSats: 0, spendingBalanceSats: 0, scope: scope)
            await fulfillment(of: [validated], timeout: 5)
            observation.cancel()
            XCTAssertEqual(app.manualEntryValidationResult, result)
            if result == .onchainOnly {
                XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "HardwareOnchainOnlyToast")
            }
        }
    }

    func testOtherInputsRemainWithTheirExistingScanner() throws {
        for input in ["bitcoin:bcrt1qexample", "lightning:lnbcrt1example", "pubkyexample", ""] {
            XCTAssertNil(try resolveUsdtPaymentRoute(input: input, isEnabled: true), input)
        }
    }
}
