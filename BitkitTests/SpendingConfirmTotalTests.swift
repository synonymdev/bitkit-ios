@testable import Bitkit
import XCTest

final class SpendingConfirmTotalTests: XCTestCase {
    func testNormalPath_UsesOrderFeePlusNetworkFee() {
        XCTAssertEqual(
            SpendingConfirmTotal.leavingAmount(
                orderFeeSat: 50_000,
                networkFeeSat: 250,
                shouldUseSendAll: false,
                maxSendable: nil
            ),
            50_250
        )
    }

    func testNormalPath_IgnoresStaleMaxSendable() {
        XCTAssertEqual(
            SpendingConfirmTotal.leavingAmount(
                orderFeeSat: 50_000,
                networkFeeSat: 250,
                shouldUseSendAll: false,
                maxSendable: 99_750
            ),
            50_250
        )
    }

    func testSendAllPath_UsesMaxSendablePlusNetworkFee() {
        // balance 100_000, send-all fee 250 → maxSendable 99_750; amount leaving = 100_000
        XCTAssertEqual(
            SpendingConfirmTotal.leavingAmount(
                orderFeeSat: 50_000,
                networkFeeSat: 250,
                shouldUseSendAll: true,
                maxSendable: 99_750
            ),
            100_000
        )
    }

    func testNormalPath_SaturatesOnOverflow() {
        XCTAssertEqual(
            SpendingConfirmTotal.leavingAmount(
                orderFeeSat: UInt64.max,
                networkFeeSat: 1,
                shouldUseSendAll: false,
                maxSendable: nil
            ),
            UInt64.max
        )
    }

    func testSendAllPath_SaturatesOnOverflow() {
        XCTAssertEqual(
            SpendingConfirmTotal.leavingAmount(
                orderFeeSat: 1,
                networkFeeSat: 1,
                shouldUseSendAll: true,
                maxSendable: UInt64.max
            ),
            UInt64.max
        )
    }

    func testSendAllPath_WithoutMaxSendable_FallsBackToOrderPlusFee() {
        XCTAssertEqual(
            SpendingConfirmTotal.leavingAmount(
                orderFeeSat: 50_000,
                networkFeeSat: 250,
                shouldUseSendAll: true,
                maxSendable: nil
            ),
            50_250
        )
    }
}
