@testable import Bitkit
import XCTest

@MainActor
final class ReceiveSheetSessionTests: XCTestCase {
    func testOnlyPreparedOfflineQrBypassesConnectionOverlay() {
        XCTAssertTrue(ReceiveSheet.canDisplayOfflineInvoice(on: .qr(cjitInvoice: nil, tab: .spending), hasPreparedInvoice: true))
        XCTAssertFalse(ReceiveSheet.canDisplayOfflineInvoice(on: .qr(cjitInvoice: nil, tab: .spending), hasPreparedInvoice: false))
        XCTAssertFalse(ReceiveSheet.canDisplayOfflineInvoice(on: .qr(cjitInvoice: "cjit", tab: .spending), hasPreparedInvoice: true))
        XCTAssertFalse(ReceiveSheet.canDisplayOfflineInvoice(on: .edit(tab: .spending, onchainOnly: false), hasPreparedInvoice: true))
        XCTAssertFalse(OfflineSheetScreen.shouldShow(isConnected: false, allowOffline: true, forceShow: false))
        XCTAssertTrue(OfflineSheetScreen.shouldShow(isConnected: false, allowOffline: false, forceShow: false))
        XCTAssertTrue(OfflineSheetScreen.shouldShow(isConnected: true, allowOffline: true, forceShow: true))
    }

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
