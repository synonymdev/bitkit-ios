@testable import Bitkit
import XCTest

@MainActor
final class ReceiveEditTests: XCTestCase {
    func testHardwareOnlyEditDismissesWithoutPreparingLightningInvoice() async {
        var didDismiss = false
        var didPrepareLightningInvoice = false

        await ReceiveEdit.finishEditing(
            onchainOnly: true,
            dismiss: { didDismiss = true },
            prepareLightningInvoice: { didPrepareLightningInvoice = true }
        )

        XCTAssertTrue(didDismiss)
        XCTAssertFalse(didPrepareLightningInvoice)
    }
}
