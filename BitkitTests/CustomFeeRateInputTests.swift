@testable import Bitkit
import XCTest

final class CustomFeeRateInputTests: XCTestCase {
    func testFirstKeyReplacesPresetAndLaterKeysAppend() {
        let first = customFeeRate(after: "2", from: 1, replacing: true)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(customFeeRate(after: "5", from: first, replacing: false), 25)
    }

    func testDeleteClearsPreset() {
        XCTAssertEqual(customFeeRate(after: "delete", from: 12, replacing: true), 0)
        XCTAssertEqual(customFeeRate(after: "delete", from: 12, replacing: false), 1)
    }

    func testInputStopsAtThreeDigits() {
        XCTAssertEqual(customFeeRate(after: "9", from: 999, replacing: false), 999)
    }
}
