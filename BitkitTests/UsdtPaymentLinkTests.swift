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
        for input in [recipient, "bitcoin:bcrt1qexample", "lightning:lnbcrt1example", "pubkyexample", ""] {
            XCTAssertNil(try resolveUsdtPaymentRoute(input: input, isEnabled: true), input)
        }
    }
}
