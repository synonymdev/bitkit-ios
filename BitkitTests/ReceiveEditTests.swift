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

    func testReplacingEditedQrRouteRemovesStaleCjitQr() {
        var navigationPath: [ReceiveRoute] = [
            .tag,
            .edit(tab: .spending, onchainOnly: false),
            .cjitGeoBlocked,
            .qr(cjitInvoice: "stale-cjit-invoice", tab: .spending),
            .edit(tab: .spending, onchainOnly: false, replacesCurrentQr: true),
        ]

        ReceiveEdit.replaceEditedQrRoute(in: &navigationPath, with: .qr(cjitInvoice: nil, tab: .spending))

        XCTAssertEqual(
            navigationPath,
            [
                .tag,
                .qr(cjitInvoice: nil, tab: .spending),
            ]
        )
    }

    func testReplacingEditedQrRouteCanNavigateToFreshCjitFlow() {
        var navigationPath: [ReceiveRoute] = [
            .qr(cjitInvoice: "stale-cjit-invoice", tab: .spending),
            .edit(tab: .spending, onchainOnly: false, replacesCurrentQr: true),
        ]

        ReceiveEdit.replaceEditedQrRoute(in: &navigationPath, with: .cjitAmount)

        XCTAssertEqual(navigationPath, [.cjitAmount])
    }
}
