@testable import Bitkit
import XCTest

@MainActor
final class ReceiveSheetSessionTests: XCTestCase {
    func testReceiveSheetItemGetsFreshIdentityPerPresentation() {
        let sheets = SheetViewModel()

        sheets.showSheet(.receive)
        let firstID = sheets.receiveSheetItem?.id

        sheets.hideSheet(reason: "test")
        sheets.showSheet(.receive)
        let secondID = sheets.receiveSheetItem?.id

        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)
    }
}
