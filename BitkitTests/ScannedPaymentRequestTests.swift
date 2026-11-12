@testable import Bitkit
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

    func testOtherBitcoinRequestsAreKept() {
        let unified = "bitcoin:bc1qtest?lightning=lnbc1"
        XCTAssertEqual(ScannedPaymentRequest.normalized(unified), unified)
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?amount=0.001"), "bitcoin:?amount=0.001")
        XCTAssertEqual(ScannedPaymentRequest.normalized("bitcoin:?lightning="), "bitcoin:?lightning=")
    }
}
