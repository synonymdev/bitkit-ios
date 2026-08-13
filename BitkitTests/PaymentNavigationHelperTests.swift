@testable import Bitkit
import XCTest

final class PaymentNavigationHelperTests: XCTestCase {
    func testQuickpayIsBlockedWhenPinIsRequiredForPayments() {
        XCTAssertTrue(
            PaymentNavigationHelper.isBlockedByPaymentPin(pinEnabled: true, requirePinForPayments: true)
        )
    }

    func testQuickpayIsAllowedWhenPinForPaymentsIsOff() {
        XCTAssertFalse(
            PaymentNavigationHelper.isBlockedByPaymentPin(pinEnabled: true, requirePinForPayments: false)
        )
        XCTAssertFalse(
            PaymentNavigationHelper.isBlockedByPaymentPin(pinEnabled: false, requirePinForPayments: true)
        )
        XCTAssertFalse(
            PaymentNavigationHelper.isBlockedByPaymentPin(pinEnabled: false, requirePinForPayments: false)
        )
    }
}
