@testable import Bitkit
import XCTest

final class DustChangeHelperTests: XCTestCase {
    private let dustLimit: UInt64 = 547

    // MARK: - Change would be dust -> use sendAll

    func testChangeBelowDustLimit_ShouldUseSendAll() {
        // totalInput: 100_000, amount: 99_500, fee: 500 -> change = 0
        XCTAssertTrue(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 99500,
            normalFee: 500,
            dustLimit: dustLimit
        ))

        // totalInput: 100_000, amount: 99_000, fee: 500 -> change = 500 (below 547)
        XCTAssertTrue(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 99000,
            normalFee: 500,
            dustLimit: dustLimit
        ))

        // totalInput: 100_000, amount: 98_954, fee: 500 -> change = 546 (just below dust)
        XCTAssertTrue(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 98954,
            normalFee: 500,
            dustLimit: dustLimit
        ))
    }

    func testChangeAtDustLimit_ShouldNotUseSendAll() {
        // change = 547 is at the limit; < 547 means dust. So 547 is NOT dust.
        // totalInput: 100_000, amount: 98_953, fee: 500 -> change = 547 (at limit, NOT dust)
        XCTAssertFalse(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 98953,
            normalFee: 500,
            dustLimit: dustLimit
        ))
    }

    func testChangeAboveDustLimit_ShouldNotUseSendAll() {
        // totalInput: 100_000, amount: 98_000, fee: 500 -> change = 1_500
        XCTAssertFalse(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 98000,
            normalFee: 500,
            dustLimit: dustLimit
        ))

        // totalInput: 100_000, amount: 98_954, fee: 495 -> change = 551
        XCTAssertFalse(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 98954,
            normalFee: 495,
            dustLimit: dustLimit
        ))
    }

    func testMaxSend_ChangeZero_ShouldUseSendAll() {
        // totalInput: 100_000, amount: 99_500, fee: 500 -> change = 0 (max case)
        XCTAssertTrue(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 99500,
            normalFee: 500,
            dustLimit: dustLimit
        ))
    }

    func testInsufficientFunds_NegativeChange_ShouldNotUseSendAll() {
        // totalInput: 100_000, amount: 100_000, fee: 500 -> change = -500
        XCTAssertFalse(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 100_000,
            normalFee: 500,
            dustLimit: dustLimit
        ))
    }

    func testUsesEnvDustLimit_WhenNotSpecified() {
        // Verify default uses Env.dustLimit (547): change 546 is dust
        XCTAssertTrue(DustChangeHelper.shouldUseSendAllToAvoidDust(
            totalInput: 100_000,
            amountSats: 99454,
            normalFee: 0
            // dustLimit omitted -> uses Env.dustLimit
        ))
    }
}
