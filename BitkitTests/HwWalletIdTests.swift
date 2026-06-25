@testable import Bitkit
import XCTest

final class HwWalletIdTests: XCTestCase {
    func testDeterministicForSameXpubs() throws {
        let a = try HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let b = try HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        XCTAssertEqual(a, b, "id derives deterministically from xpubs")
    }

    func testOrderIndependent() throws {
        let a = try HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let b = try HwWalletId.derive(xpubs: ["taproot": "zTR", "nativeSegwit": "zNS"])
        XCTAssertEqual(a, b, "values are sorted before hashing")
    }

    func testDifferentXpubsProduceDifferentIds() throws {
        let a = try HwWalletId.derive(xpubs: ["nativeSegwit": "zNS"])
        let b = try HwWalletId.derive(xpubs: ["nativeSegwit": "DIFFERENT"])
        XCTAssertNotEqual(a, b)
    }

    func testPrefix() throws {
        XCTAssertTrue(try HwWalletId.derive(xpubs: ["nativeSegwit": "z"]).hasPrefix("trezor:"))
    }

    func testThrowsWhenNoXpubs() {
        XCTAssertThrowsError(try HwWalletId.derive(xpubs: [:]))
    }
}
