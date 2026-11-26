@testable import Bitkit
import SwiftUI
import XCTest

/// The Later row pairs a long subtitle with "≈ ₿ 99", so the amount must keep its full width.
@MainActor
final class FeeItemAmountTests: XCTestCase {
    func testTheAmountKeepsItsWidthWhenTheRowIsNarrow() {
        let view = FeeItemAmount(amount: 99, prefix: "≈")
            .environmentObject(CurrencyViewModel())
            .environmentObject(SettingsViewModel.shared)
        let controller = UIHostingController(rootView: view)

        let ideal = controller.sizeThatFits(in: CGSize(width: 1000, height: 1000))
        let squeezed = controller.sizeThatFits(in: CGSize(width: 20, height: 1000))

        XCTAssertGreaterThan(ideal.width, 20)
        XCTAssertEqual(squeezed.width, ideal.width, accuracy: 0.5, "The amount was clipped or wrapped")
        XCTAssertEqual(squeezed.height, ideal.height, accuracy: 0.5, "The amount wrapped onto more lines")
    }
}
