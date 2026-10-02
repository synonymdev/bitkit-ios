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

    // MARK: - Jade

    func testJadeUsesItsModel() {
        XCTAssertEqual(resolveHwWalletName(label: nil, model: "Jade Plus", vendor: .blockstream), "Jade Plus")
    }

    func testJadeFallsBackToJadeWithoutModel() {
        XCTAssertEqual(resolveHwWalletName(label: nil, model: nil, vendor: .blockstream), "Jade")
    }

    func testJadeBlankModelFallsBackToJade() {
        XCTAssertEqual(resolveHwWalletName(label: nil, model: "  ", vendor: .blockstream), "Jade")
    }

    func testJadeIgnoresTheDeviceLabel() {
        XCTAssertEqual(resolveHwWalletName(label: "Jade 8F6B64", model: "Jade", vendor: .blockstream), "Jade")
    }

    func testJadeCustomLabelWins() {
        XCTAssertEqual(
            resolveHwWalletName(label: nil, model: "Jade", customLabel: "Travel", vendor: .blockstream),
            "Travel"
        )
    }

    func testJadeModelIsNotPrefixedWithTrezor() {
        XCTAssertEqual(resolveHwWalletName(label: nil, model: "Jade", vendor: .blockstream), "Jade")
    }

    func testAJadeEntryIsNamedAsAJade() {
        let entry = HwKnownDevice(
            id: "jade:bluetooth:aabbcc",
            name: "Jade AABBCC",
            path: "ble:jade",
            transportType: "bluetooth",
            label: "Jade AABBCC",
            model: "Jade Plus",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            vendor: .blockstream
        )

        XCTAssertEqual(entry.displayName, "Jade Plus")
    }
}
