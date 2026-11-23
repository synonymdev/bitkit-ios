@testable import Bitkit
import XCTest

final class ReceiveNearbyOfferTests: XCTestCase {
    func testOnlyARequestShownOnScreenIsOffered() {
        XCTAssertTrue(ReceiveQr.showsRequest(needsInvoiceRefresh: false, isReceiveUnavailable: false))
        // Savings after leaving USDT: the refresh is pending or failed, so the page shows a spinner or Retry.
        XCTAssertFalse(ReceiveQr.showsRequest(needsInvoiceRefresh: true, isReceiveUnavailable: false))
        XCTAssertFalse(ReceiveQr.showsRequest(needsInvoiceRefresh: false, isReceiveUnavailable: true))
    }

    func testUsdtRequestIsNotOfferedBehindTheConnectionIssuesScreen() {
        let uri = "ethereum:0xabc@42161"
        func offered(isCovered: Bool) -> String? {
            UsdtReceiveView.nearbyRequest(receiveUri: uri, isEnabled: true, showsAddress: true, hasDeposit: false, isCovered: isCovered)
        }
        XCTAssertNotNil(offered(isCovered: false))
        XCTAssertNil(offered(isCovered: true))
    }
}
