@testable import Bitkit
import XCTest

final class ReceiveTabsTests: XCTestCase {
    func testWithoutLightningReceiveTheSpendingAndAutoTabsHide() {
        XCTAssertEqual(ReceiveQr.visibleTabs(hasHardwareWallet: false, canReceiveLightning: false, isUsdtEnabled: false), [.savings])
        XCTAssertEqual(
            ReceiveQr.visibleTabs(hasHardwareWallet: true, canReceiveLightning: false, isUsdtEnabled: true),
            [.hardware, .savings, .usdt]
        )
    }

    func testWithLightningReceiveEveryTabShowsInOrder() {
        XCTAssertEqual(
            ReceiveQr.visibleTabs(hasHardwareWallet: true, canReceiveLightning: true, isUsdtEnabled: true),
            [.hardware, .savings, .unified, .spending, .usdt]
        )
        XCTAssertEqual(
            ReceiveQr.visibleTabs(hasHardwareWallet: false, canReceiveLightning: true, isUsdtEnabled: false),
            [.savings, .unified, .spending]
        )
    }

    func testAutoAndSpendingFallBackToSavingsWhenLightningReceiveHides() {
        XCTAssertEqual(ReceiveQr.tab(.unified, canShowUnifiedReceive: false), .savings)
        XCTAssertEqual(ReceiveQr.tab(.spending, canShowUnifiedReceive: false), .savings)
        XCTAssertEqual(ReceiveQr.tab(.usdt, canShowUnifiedReceive: false), .usdt)
        XCTAssertEqual(ReceiveQr.tab(.spending, canShowUnifiedReceive: true), .spending)
    }
}
