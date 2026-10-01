@testable import Bitkit
import XCTest

@MainActor
final class SheetViewModelTests: XCTestCase {
    func testLateDismissOfPreviousSheetKeepsNextSheetOpen() {
        let sheets = SheetViewModel()

        sheets.showSheet(.quickpay)
        sheets.hideSheet(reason: "Quickpay later")
        sheets.showSheet(.subscription, data: SubscriptionSheetItem(route: .create))

        // SwiftUI runs the quickpay sheet's onDismiss after its dismiss animation,
        // by which time the subscription sheet is already active.
        sheets.hideSheetIfActive(.quickpay, reason: "Quickpay sheet dismissed")

        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .subscription)
        XCTAssertNotNil(sheets.subscriptionSheetItem)
    }

    func testDismissOfActiveSheetHidesIt() {
        let sheets = SheetViewModel()

        sheets.showSheet(.quickpay)
        sheets.hideSheetIfActive(.quickpay, reason: "Quickpay sheet dismissed")

        XCTAssertNil(sheets.activeSheetConfiguration)
    }
}
