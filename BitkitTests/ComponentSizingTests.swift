@testable import Bitkit
import BitkitCore
import SwiftUI
import XCTest

@MainActor
final class ComponentSizingTests: XCTestCase {
    func testButtonsPreserveDefaultHeightsAndGrowForLargeText() {
        for variant in [CustomButton.Variant.primary, .secondary, .tertiary] {
            for isLoading in [false, true] {
                let button = CustomButton(title: "Continue", variant: variant, isLoading: isLoading)
                XCTAssertEqual(height(of: button, width: 343, size: .large), 56, accuracy: 1)
            }
            let title = "Cross-Network Deposits"
            let button = CustomButton(title: title, variant: variant)
            let textHeight = height(of: BodySSBText(title).fixedSize(horizontal: false, vertical: true), width: 311, size: .accessibility5)
            XCTAssertGreaterThanOrEqual(height(of: button, width: 343, size: .accessibility5), textHeight + 24)
        }
        let manualEntry = RectangleButton(icon: "pencil", title: "Enter Manually", testID: "ManualEntry", action: {})
        XCTAssertEqual(height(of: manualEntry, width: 343, size: .large), 72, accuracy: 1)
        XCTAssertGreaterThan(height(of: manualEntry, width: 343, size: .accessibility5), 72)
        for variant in [CustomButton.Variant.primary, .secondary] {
            XCTAssertEqual(height(of: CustomButton(title: "Details", variant: variant, size: .small), width: 160, size: .large), 40, accuracy: 1)
        }
    }

    func testTitlesAndCameraPermissionGrowForLargeText() {
        let header = NavigationBar(title: "Cross-Network Deposits")
            .environmentObject(AppViewModel()).environmentObject(NavigationViewModel())
        XCTAssertEqual(height(of: header, width: 343, size: .large), 48, accuracy: 1)
        XCTAssertGreaterThan(height(of: header, width: 343, size: .accessibility5), 100)
        let sheet = SheetHeader(title: "Select Network", showBackButton: true)
        XCTAssertGreaterThan(height(of: sheet, width: 280, size: .accessibility5), height(of: sheet, width: 280, size: .large))
        let permission = ScannerPermissionRequest(onRequestPermission: {}).fixedSize(horizontal: false, vertical: true)
        XCTAssertGreaterThan(height(of: permission, width: 280, size: .accessibility5), height(of: permission, width: 280, size: .large))
    }

    func testDepositRowsGrowToShowNetworkStatusAndAmountAtAccessibilitySizes() {
        let deposit = UsdtDeposit(id: "deposit", network: "bsc", asset: "USDT", amount: 50_000_001,
                                  sourceTx: "0x" + String(repeating: "ab", count: 32), status: "held",
                                  code: "standing_route_unavailable", refundTx: nil)
        let row = UsdtDepositRow(deposit: deposit, hideBalance: false)
        let normal = height(of: row, width: 320, size: .large)
        let accessible = height(of: row, width: 320, size: .accessibility5)
        XCTAssertGreaterThan(accessible, normal * 2)
        let status = BodyMSBText(deposit.networkLabel).fixedSize(horizontal: false, vertical: true)
        let amount = BodyMSBText("50.000001 USDT").fixedSize(horizontal: false, vertical: true)
        XCTAssertGreaterThan(accessible, height(of: status, width: 288, size: .accessibility5)
            + height(of: amount, width: 288, size: .accessibility5))
    }

    private func height(of view: some View, width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        let controller = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        return controller.sizeThatFits(in: CGSize(width: width, height: 10000)).height
    }
}
