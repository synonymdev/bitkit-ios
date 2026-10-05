@testable import Bitkit
import UIKit
import XCTest

/// Each vendor's illustrations resolve in the app bundle and its copy comes from its own keys, so a
/// Jade never shows Trezor art or wording.
final class HwWalletVendorPresentationTests: XCTestCase {
    func testTheDeviceIllustrationsResolveInTheAppBundle() {
        for name in ["jade-placeholder", "trezor-device", "trezor-card"] {
            XCTAssertNotNil(UIImage(named: name), name)
        }
        for vendor in HwWalletVendor.allCases {
            XCTAssertNotNil(UIImage(named: vendor.deviceImageName), "\(vendor)")
            XCTAssertNotNil(UIImage(named: vendor.signImageName), "\(vendor)")
        }
    }

    func testTheJadePlaceholderKeepsItsVectorSize() throws {
        let image = try XCTUnwrap(UIImage(named: "jade-placeholder"))

        XCTAssertEqual(image.size, CGSize(width: 256, height: 256))
    }

    func testTrezorKeepsItsArtAndCopy() {
        let vendor = HwWalletVendor.trezor

        XCTAssertEqual(vendor.deviceImageName, "trezor-device")
        XCTAssertEqual(vendor.signImageName, "trezor-card")
        XCTAssertEqual(vendor.modelName, t("hardware__device_model_trezor"))
        XCTAssertEqual(vendor.foundHeader, t("hardware__found_header"))
        XCTAssertEqual(vendor.pairedHeader, t("hardware__paired_header"))
        XCTAssertEqual(vendor.sendSignButtonTitle, t("hardware__send_open_connect"))
        XCTAssertEqual(vendor.transferSignButtonTitle, t("lightning__transfer_hw__open_connect"))
        XCTAssertTrue(vendor.supportsPassphraseWallets)
    }

    func testJadeHasItsOwnArtAndCopy() {
        let vendor = HwWalletVendor.blockstream

        XCTAssertEqual(vendor.deviceImageName, "jade-placeholder")
        XCTAssertEqual(vendor.signImageName, "jade-placeholder")
        XCTAssertEqual(vendor.modelName, t("hardware__device_model_jade"))
        XCTAssertEqual(vendor.modelName, "Jade")
        XCTAssertEqual(vendor.foundHeader, t("hardware__found_header_jade"))
        XCTAssertEqual(vendor.pairedHeader, t("hardware__paired_header_jade"))
        XCTAssertEqual(vendor.sendSignButtonTitle, t("hardware__send_open_connect_jade"))
        XCTAssertEqual(vendor.transferSignButtonTitle, t("hardware__send_open_connect_jade"))
        XCTAssertFalse(vendor.supportsPassphraseWallets)
    }

    func testNoJadeCopyMentionsTrezor() {
        let vendor = HwWalletVendor.blockstream
        let copy = [vendor.modelName, vendor.foundHeader, vendor.pairedHeader, vendor.sendSignButtonTitle, vendor.transferSignButtonTitle]

        for text in copy {
            XCTAssertFalse(text.contains("Trezor"), text)
            XCTAssertTrue(text.contains("Jade"), text)
        }
    }

    /// The shared e2e helper taps `Tab-trezor`, so a Trezor wallet's receive tab keeps its name.
    func testTheHardwareReceiveTabIsNamedAfterTheWalletVendor() {
        let trezorTab = TabItem(ReceiveQr.ReceiveTab.hardware, label: HwWalletVendor.trezor.modelName)
        let jadeTab = TabItem(ReceiveQr.ReceiveTab.hardware, label: HwWalletVendor.blockstream.modelName)

        XCTAssertEqual(trezorTab.title, "Trezor")
        XCTAssertEqual(trezorTab.resolvedAccessibilityIdentifier, "Tab-trezor")
        XCTAssertEqual(jadeTab.title, "Jade")
        XCTAssertEqual(jadeTab.resolvedAccessibilityIdentifier, "Tab-jade")
    }

    func testTheHardwareReceiveTabWithoutAWalletIsNamedHardware() {
        let tab = TabItem(ReceiveQr.ReceiveTab.hardware)

        XCTAssertEqual(tab.title, t("hardware__receive_tab_hardware"))
        XCTAssertEqual(tab.title, "Hardware")
        XCTAssertEqual(tab.resolvedAccessibilityIdentifier, "Tab-hardware")
    }
}
