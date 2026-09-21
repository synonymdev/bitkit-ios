@testable import Bitkit
import XCTest

final class HwWalletNameTests: XCTestCase {
    func testLabelUsedWhenItDiffersFromModel() {
        XCTAssertEqual(resolveHwWalletName(label: "My Trezor", model: "Safe 5"), "My Trezor")
    }

    func testLabelMatchingModelFallsBackToPrefixedModel() {
        XCTAssertEqual(resolveHwWalletName(label: "Safe 5", model: "Safe 5"), "Trezor Safe 5")
    }

    func testModelPrefixedWhenNoLabel() {
        XCTAssertEqual(resolveHwWalletName(label: nil, model: "Safe 5"), "Trezor Safe 5")
    }

    func testModelAlreadyPrefixedIsNotDoublePrefixed() {
        XCTAssertEqual(resolveHwWalletName(label: nil, model: "Trezor Model T"), "Trezor Model T")
    }

    func testNilLabelAndModelFallsBackToVendor() {
        XCTAssertEqual(resolveHwWalletName(label: nil, model: nil), "Trezor")
    }

    func testEmptyLabelFallsBackToModel() {
        XCTAssertEqual(resolveHwWalletName(label: "", model: "Safe 5"), "Trezor Safe 5")
    }

    func testCustomLabelTakesPriorityOverLabelAndModel() {
        XCTAssertEqual(
            resolveHwWalletName(label: "My Trezor", model: "Safe 5", customLabel: "Cold Storage"),
            "Cold Storage"
        )
    }

    func testEmptyCustomLabelFallsBackToLabel() {
        XCTAssertEqual(
            resolveHwWalletName(label: "My Trezor", model: "Safe 5", customLabel: ""),
            "My Trezor"
        )
    }

    func testNilCustomLabelFallsBackToPrefixedModel() {
        XCTAssertEqual(
            resolveHwWalletName(label: nil, model: "Safe 5", customLabel: nil),
            "Trezor Safe 5"
        )
    }
}
