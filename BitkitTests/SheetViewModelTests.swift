@testable import Bitkit
import XCTest

@MainActor
final class SheetViewModelTests: XCTestCase {
    func testReceivedTransactionCanReplaceOnlyReceive() {
        let sheets = SheetViewModel()
        XCTAssertTrue(sheets.canPresentReceivedTx)
        for id in SheetID.allCases {
            sheets.activeSheetConfiguration = SheetConfiguration(id: id, data: nil)
            XCTAssertEqual(sheets.canPresentReceivedTx, id == .receive, id.rawValue)
        }
    }

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

    func testLateDismissOfReplacedSheetKeepsNewerSheetWithSameID() throws {
        let sheets = SheetViewModel()

        sheets.showSheet(.pubkyAuthApproval)
        let replaced = try XCTUnwrap(sheets.activeSheetConfiguration)
        sheets.hideSheet(reason: "Same link handled again")
        sheets.showSheet(.pubkyAuthApproval)
        let current = try XCTUnwrap(sheets.activeSheetConfiguration)

        // The replaced sheet disappears after its successor is shown, and both share the sheet ID.
        sheets.hideSheetIfActive(presentationID: replaced.presentationID, reason: "Pubky auth approval sheet dismissed")

        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, current.presentationID)

        sheets.hideSheetIfActive(presentationID: current.presentationID, reason: "Pubky auth approval sheet dismissed")

        XCTAssertNil(sheets.activeSheetConfiguration)
    }
}
