@testable import Bitkit
import BitkitCore
import Combine
import XCTest

@MainActor
final class Bip21DecodingTests: XCTestCase {
    private let address = "bcrt1qr289x0fhg62672e8urudfnxnsr8tcax64xk2vk"

    private var duplicatedURI: String {
        "bitcoin:\(address)?amount=0.0000002&message=Bitkit" +
            "bitcoin:\(address)?amount=0.0000003&message=Bitkit"
    }

    func testCoreRejectsDuplicateSingletonParameters() async {
        for uri in [
            duplicatedURI,
            "bitcoin:\(address)?amount=0.000035&AMOUNT=0.00005",
            "bitcoin:\(address)?label=first&LABEL=second",
            "bitcoin:\(address)?message=first&Message=second",
            "bitcoin:\(address)?pop=callback%3a&req-pop=callback%3a",
        ] {
            do {
                _ = try await decode(invoice: uri)
                XCTFail("Expected duplicate singleton parameters to fail: \(uri)")
            } catch DecodingError.InvalidFormat {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCorePreservesBitcoinTextInQueryMetadata() async throws {
        for (key, value) in [
            ("message", "bitcoin:donation"),
            ("label", "BITCOIN:donation"),
            ("custom", "bitcoin:1BoatSLRHtKNngkdXEeobR76b53LETtpyT"),
            ("message", "Why?"),
        ] {
            let data = try await decode(invoice: "bitcoin:\(address)?amount=0.000035&\(key)=\(value)")
            guard case let .onChain(invoice) = data else {
                return XCTFail("Expected an on-chain invoice")
            }
            XCTAssertEqual(invoice.address, address)
            XCTAssertEqual(invoice.amountSatoshis, 3500)
            XCTAssertEqual(invoice.params?[key], value)
        }
    }

    func testShopDecodeFailureThrowsWithoutReplacingPreviousInvoice() async {
        let app = AppViewModel()
        app.scannedOnchainInvoice = OnChainInvoice(
            address: address, amountSatoshis: 42, label: nil, message: "Previous invoice", params: [:]
        )

        do {
            try await app.handleScannedData(duplicatedURI, scope: .paymentRequests)
            XCTFail("Expected Shop decoding to throw instead of returning success")
        } catch DecodingError.InvalidFormat {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, 42)
        XCTAssertEqual(app.scannedOnchainInvoice?.message, "Previous invoice")
        XCTAssertNil(app.scannedLightningInvoice)
    }

    func testValidBitcoinNoteReachesPaymentStateInEveryPaymentScope() async throws {
        for scope: ScanHandlingScope in [.unrestricted, .paymentRequests, .onchainPayments] {
            let app = AppViewModel()
            try await app.handleScannedData(
                "bitcoin:\(address)?amount=0.000035&message=bitcoin:donation",
                scope: scope,
                alternativeOnchainBalanceSats: 100_000
            )
            XCTAssertEqual(app.scannedOnchainInvoice?.address, address)
            XCTAssertEqual(app.scannedOnchainInvoice?.amountSatoshis, 3500)
            XCTAssertEqual(app.scannedOnchainInvoice?.message, "bitcoin:donation")
        }
    }

    func testManualEntryUsesCoreValidation() async {
        for (uri, expected): (String, ManualEntryValidationResult) in [
            ("bitcoin:\(address)?amount=0.000035&message=bitcoin:donation", .valid),
            (duplicatedURI, .invalid),
        ] {
            let app = AppViewModel()
            let validated = expectation(description: "manual entry validated")
            let subscription = app.$manualEntryValidationResult.dropFirst().sink { result in
                XCTAssertEqual(result, expected)
                validated.fulfill()
            }
            app.validateManualEntryInput(uri, savingsBalanceSats: 100_000, spendingBalanceSats: 0)
            await fulfillment(of: [validated], timeout: 5)
            XCTAssertEqual(app.isManualEntryInputValid, expected == .valid)
            subscription.cancel()
        }
    }
}
