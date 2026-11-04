@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class AppViewModelTests: XCTestCase {
    private let address = "bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x"

    override func setUp() {
        super.setUp()
        ToastWindowManager.shared.hideToast()
        addTeardownBlock { ToastWindowManager.shared.hideToast() }
    }

    func testBip21AmountUpToBitcoinSupplyOpensOnchainPayment() async throws {
        let app = makeApp()

        try await app.handleScannedData("bitcoin:\(address)?amount=21000000")

        XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, Env.maxBitcoinSats)
    }

    func testBip21AmountAboveBitcoinSupplyIsRejected() async throws {
        // bitkit-core saturates these: 1e11 BTC is 1e19 sats and `inf` is UInt64.max.
        for amount in ["21000000.00000001", "100000000000", "inf"] {
            let app = makeApp()
            ToastWindowManager.shared.hideToast()

            try await app.handleScannedData("bitcoin:\(address)?amount=\(amount)")

            XCTAssertNil(app.scannedOnchainInvoice, amount)
            XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "InvalidAddressToast", amount)
        }
    }

    func testContactEndpointWithAmountAboveBitcoinSupplyIsNotOffered() async throws {
        let usdt = try PaykitUsdt.endpoint(address: "0x4cdDcC65AF3Aa77803d1A99A030eb17751AC7780")
        let request = "bitcoin:\(address)?amount=inf"
        let bitcoin = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh, value: request, min: nil, max: nil, rawPayload: request
        )
        let app = makeApp()
        let context = ContactPaymentContext(publicKey: "contact", endpoints: [usdt, bitcoin])
        XCTAssertTrue(app.claimContactPaymentContext(context))

        try await app.handleScannedData(usdt.paymentRequest, claimedContactPaymentContext: context)

        XCTAssertNil(app.scannedOnchainInvoice)
    }

    func testManualEntryRejectsAmountsAboveBitcoinSupply() async {
        let app = AppViewModel()
        let cases: [(String, ManualEntryValidationResult)] = [
            ("bitcoin:\(address)?amount=0.001", .valid),
            ("bitcoin:\(address)?amount=100000000000", .invalid),
            ("bitcoin:\(address)?amount=inf", .invalid),
        ]
        for (input, result) in cases {
            ToastWindowManager.shared.hideToast()
            let validated = expectation(description: "Manual entry validated")
            let observation = app.$manualEntryValidationResult.dropFirst().sink { _ in validated.fulfill() }

            app.validateManualEntryInput(input, savingsBalanceSats: 100_000, spendingBalanceSats: 0)

            await fulfillment(of: [validated], timeout: 5)
            observation.cancel()
            XCTAssertEqual(app.manualEntryValidationResult, result, input)
            if result == .invalid {
                XCTAssertEqual(ToastWindowManager.shared.currentToast?.accessibilityIdentifier, "InvalidAddressToast", input)
            }
        }
    }

    private func makeApp() -> AppViewModel {
        AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: false,
                        spendableOnchainBalanceSats: 0,
                        totalLightningBalanceSats: 0,
                        hasChannels: false,
                        hasUsableChannels: false
                    )
                },
                canSendLightning: { _ in false }
            )
        )
    }
}
