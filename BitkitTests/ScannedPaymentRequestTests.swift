@testable import Bitkit
import BitkitCore
import XCTest

final class ScannedPaymentRequestTests: XCTestCase {
    private let invoice = PosNfcFixtures.squareInvoice

    func testSquareRequestIsKept() {
        XCTAssertEqual(invoice.count, 447)
        XCTAssertEqual(ScannedPaymentRequest.normalized(PosNfcFixtures.squareUri), PosNfcFixtures.squareUri)
        XCTAssertEqual(ScannedPaymentRequest.normalized(" LIGHTNING:LNTBS1P\n"), "LIGHTNING:LNTBS1P")
    }

    func testBip321RequestWithoutAddressBecomesItsLightningRequest() {
        XCTAssertEqual(ScannedPaymentRequest.normalized(PosNfcFixtures.bip321Uri), "lightning:\(invoice)")
        XCTAssertEqual(ScannedPaymentRequest.normalized("BITCOIN:?LIGHTNING=\(invoice)"), "lightning:\(invoice)")
        XCTAssertEqual(
            ScannedPaymentRequest.normalized("bitcoin:?amount=0.0000799&lightning=\(invoice)&creq=x"),
            "lightning:\(invoice)"
        )
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?lno=lno1qgsq"), "lightning:lno1qgsq")
    }

    func testRequestWithRequiredParameterIsKept() {
        let required = "bitcoin:?lightning=\(invoice)&req-pop=callback%3a"
        XCTAssertEqual(ScannedPaymentRequest.normalized(required), required)
        let uppercase = "BITCOIN:?REQ-FOO=bar&LIGHTNING=\(invoice)"
        XCTAssertEqual(ScannedPaymentRequest.normalized(uppercase), uppercase)
        for empty in ["bitcoin:?lightning=\(invoice)&req-foo=", "bitcoin:?lightning=\(invoice)&req-foo"] {
            XCTAssertEqual(ScannedPaymentRequest.normalized(empty), empty)
        }
    }

    func testRequestWithARepeatedParameterIsKept() {
        for repeated in [
            "bitcoin:?amount=0.01&AMOUNT=0.02&lightning=\(invoice)",
            "bitcoin:?lightning=\(invoice)&amount=0.0000799&amount=0.0000799",
            // Valid BIP 321, but which invoice to pay is not chosen here.
            "bitcoin:?lightning=\(invoice)&lightning=\(invoice)",
            "bitcoin:?amount=&amount=0.02&lightning=\(invoice)",
            "bitcoin:?label=a&lightning=\(invoice)&Label=a",
            "bitcoin:?message=a&message=b&lightning=\(invoice)",
            "bitcoin:?pop=a%3a&pop=b%3a&lightning=\(invoice)",
        ] {
            XCTAssertEqual(ScannedPaymentRequest.normalized(repeated), repeated)
        }
    }

    func testRequestRepeatingAnOptionalExtensionIsUnwrapped() {
        XCTAssertEqual(
            ScannedPaymentRequest.normalized("bitcoin:?x-shop=a&lightning=\(invoice)&X-SHOP=b&amount=0.0000799"),
            "lightning:\(invoice)"
        )
    }

    func testRepeatedOffersBesideOneInvoiceAreSkipped() {
        let offers = "lno=lno1qgsqvgnwgcg35z6ee2h3yczraddm72xrfua9uve2rlrm9deu7xyfzr&LNO=lno1pqps7sjqpgt"
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?\(offers)&lightning=\(invoice)"), "lightning:\(invoice)")
        XCTAssertTrue(ScannerManager.isNearbyPaymentRequest(ScannedPaymentRequest.normalized("bitcoin:?lightning=\(invoice)&\(offers)")))
        // Offers alone are still refused over Bluetooth.
        XCTAssertFalse(ScannerManager.isNearbyPaymentRequest(ScannedPaymentRequest.normalized("bitcoin:?\(offers)")))
    }

    func testScannerRejectsARepeatedParameter() async {
        await assertScannerRejects("bitcoin:?amount=0.01&AMOUNT=0.02&lightning=\(invoice)")
    }

    func testRequestWhoseAmountTheInvoiceDoesNotStateIsKept() {
        XCTAssertEqual(
            ScannedPaymentRequest.normalized("bitcoin:?amount=0.000799&lightning=\(invoice)"),
            "bitcoin:?amount=0.000799&lightning=\(invoice)"
        )
        XCTAssertEqual(
            ScannedPaymentRequest.normalized("bitcoin:?amount=0.00007990&lightning=\(invoice)"),
            "lightning:\(invoice)"
        )
        let amountless = "lnbcrt1pjqwerty"
        XCTAssertEqual(
            ScannedPaymentRequest.normalized("bitcoin:?amount=0.0001&lightning=\(amountless)"),
            "bitcoin:?amount=0.0001&lightning=\(amountless)"
        )
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?lightning=\(amountless)"), "lightning:\(amountless)")
        XCTAssertEqual(
            ScannedPaymentRequest.normalized("bitcoin:?amount=0.0025&lightning=lnbcrt2500u1pjq"),
            "lightning:lnbcrt2500u1pjq"
        )
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?amount=x&lightning=\(invoice)"), "bitcoin:?amount=x&lightning=\(invoice)")
    }

    func testRequestWithAMalformedAmountIsKept() {
        for amount in ["0.0000799BTC", "0.0000799,50", "0.0000799.0", "-0.0000799", ".", "0x1"] {
            let request = "bitcoin:?amount=\(amount)&lightning=\(invoice)"
            XCTAssertEqual(ScannedPaymentRequest.normalized(request), request, amount)
        }
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?amount=.0000799&lightning=\(invoice)"), "lightning:\(invoice)")
    }

    func testScannerRejectsAnAmountTheInvoiceDoesNotState() async {
        await assertScannerRejects("bitcoin:?amount=0.000799&lightning=\(invoice)")
    }

    private func assertScannerRejects(_ request: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let decoded = try await decode(invoice: ScannedPaymentRequest.normalized(request))
            XCTFail("Decoded \(decoded)", file: file, line: line)
        } catch {}
    }

    func testOtherBitcoinRequestsAreKept() {
        let unified = "bitcoin:bc1qtest?lightning=lnbc1"
        XCTAssertEqual(ScannedPaymentRequest.normalized(unified), unified)
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?amount=0.001"), "bitcoin:?amount=0.001")
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?lightning="), "bitcoin:?lightning=")
    }
}
