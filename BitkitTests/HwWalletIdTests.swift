@testable import Bitkit
import XCTest

final class HwWalletIdTests: XCTestCase {
    func testDeterministicForSameXpubs() {
        let a = HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"], fallbackId: "x")
        let b = HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"], fallbackId: "y")
        XCTAssertEqual(a, b, "id derives from xpubs, independent of the fallback id")
    }

    func testOrderIndependent() {
        let a = HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"], fallbackId: "x")
        let b = HwWalletId.derive(xpubs: ["taproot": "zTR", "nativeSegwit": "zNS"], fallbackId: "x")
        XCTAssertEqual(a, b, "values are sorted before hashing")
    }

    func testDifferentXpubsProduceDifferentIds() {
        let a = HwWalletId.derive(xpubs: ["nativeSegwit": "zNS"], fallbackId: "x")
        let b = HwWalletId.derive(xpubs: ["nativeSegwit": "DIFFERENT"], fallbackId: "x")
        XCTAssertNotEqual(a, b)
    }

    func testPrefix() {
        XCTAssertTrue(HwWalletId.derive(xpubs: ["nativeSegwit": "z"], fallbackId: "x").hasPrefix("trezor:"))
    }

    func testFallsBackToDeviceIdWhenNoXpubs() {
        XCTAssertEqual(HwWalletId.derive(xpubs: [:], fallbackId: "device-123"), "trezor:device-123")
    }
}
