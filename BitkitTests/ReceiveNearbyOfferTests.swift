@testable import Bitkit
import XCTest

final class ReceiveNearbyOfferTests: XCTestCase {
    func testOnlyARequestShownOnScreenIsOffered() {
        XCTAssertTrue(ReceiveQr.showsRequest(needsInvoiceRefresh: false, isReceiveUnavailable: false))
        // Savings after leaving USDT: the refresh is pending or failed, so the page shows a spinner or Retry.
        XCTAssertFalse(ReceiveQr.showsRequest(needsInvoiceRefresh: true, isReceiveUnavailable: false))
        XCTAssertFalse(ReceiveQr.showsRequest(needsInvoiceRefresh: false, isReceiveUnavailable: true))
    }
}
