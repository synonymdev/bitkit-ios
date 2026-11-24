@testable import Bitkit
import XCTest

@MainActor
final class TimedSheetManagerTests: XCTestCase {
    private struct FakeSheet: TimedSheetItem {
        let id: SheetID
        let priority: TimedSheetPriority
        let sheetItem: any SheetItem

        func shouldShow() async -> Bool {
            true
        }

        func onShown() {}
        func onDismissed() {}
    }

    override func tearDown() async throws {
        TimedSheetManager.shared.onPrimaryScreenExited()
        TimedSheetManager.shared.removeSheet(withId: .appUpdate)
        TimedSheetManager.shared.removeSheet(withId: .moveToSpark)
        try await super.tearDown()
    }

    func testDismissingASheetChecksOnlyTheMoveToSparkIntro() async throws {
        let manager = TimedSheetManager.shared
        let sheets = SheetViewModel()
        let transfers = try Bitkit.TransferService(storage: Bitkit.TransferStorage(defaults: makeIsolatedDefaults()), lightningService: .shared)
        manager.setup(
            sheetViewModel: sheets, appViewModel: AppViewModel(), settingsViewModel: .shared,
            walletViewModel: WalletViewModel(
                transferService: transfers,
                sheetViewModel: sheets, feeEstimatesManager: FeeEstimatesManager()
            ),
            currencyViewModel: CurrencyViewModel(), paykitPaymentRequestManager: PaykitPaymentRequestManager()
        )
        manager.registerSheet(FakeSheet(id: .appUpdate, priority: .critical, sheetItem: AppUpdateSheetItem()))
        manager.registerSheet(FakeSheet(id: .moveToSpark, priority: .low, sheetItem: MoveToSparkSheetItem()))
        // A sheet shown at cold start keeps the first check from showing anything.
        sheets.showSheet(.receive)
        manager.onPrimaryScreenEntered()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .receive)

        sheets.hideSheet()
        manager.onSheetDismissed()
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .moveToSpark)
    }
}
