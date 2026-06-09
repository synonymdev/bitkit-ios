@testable import Bitkit
import XCTest

final class ShortChannelIdTests: XCTestCase {
    func testFormatsLndScidIntoClnForm() {
        // The two formats the issue calls out (LND uint64 and CLN block x tx x output)
        // are two encodings of the same channel.
        XCTAssertEqual(UInt64(854_845_001_888_432_128).formattedAsShortChannelId, "777477x916x0")
    }

    func testFormatsFromComponents() {
        let scid = (UInt64(700_000) << 40) | (UInt64(1) << 16) | UInt64(2)
        XCTAssertEqual(scid.formattedAsShortChannelId, "700000x1x2")
    }

    func testZeroIsAllZeroes() {
        XCTAssertEqual(UInt64(0).formattedAsShortChannelId, "0x0x0")
    }

    func testMaxComponentsStayInTheirFields() {
        let scid = (UInt64(0xFFFFFF) << 40) | (UInt64(0xFFFFFF) << 16) | UInt64(0xFFFF)
        XCTAssertEqual(scid.formattedAsShortChannelId, "16777215x16777215x65535")
    }
}
