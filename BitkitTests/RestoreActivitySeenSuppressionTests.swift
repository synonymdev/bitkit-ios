@testable import Bitkit
import XCTest

/// Regression cover for #588: the post-restore received-sheet suppression must outlive the pass that
/// marks the replayed activities as seen.
///
/// Clearing `pendingRestoreActivitySeen` up front reopened
/// `presentReceivedSheetForOnchainTransaction` while the marking pass was still running — and kept it
/// open when the pass failed — so a historical tx replayed by LDK could pop a "Received" sheet.
@MainActor
final class RestoreActivitySeenSuppressionTests: XCTestCase {
    private let flagKey = "pendingRestoreActivitySeen"

    override func setUp() {
        super.setUp()
        snapshotAppDefaults(flagKey)
    }

    func testSuppressionHoldsUntilTheMarkingPassFinishes() async {
        SettingsViewModel.shared.pendingRestoreActivitySeen = true
        let app = AppViewModel()
        var flagDuringPass: Bool?

        await app.completePendingRestoreActivitySeen {
            flagDuringPass = SettingsViewModel.shared.pendingRestoreActivitySeen
            return true
        }

        XCTAssertEqual(flagDuringPass, true, "suppression was lifted before the activities were marked seen")
        XCTAssertFalse(SettingsViewModel.shared.pendingRestoreActivitySeen)
    }

    func testSuppressionIsKeptWhenTheMarkingPassFails() async {
        SettingsViewModel.shared.pendingRestoreActivitySeen = true
        let app = AppViewModel()

        await app.completePendingRestoreActivitySeen { false }

        XCTAssertTrue(
            SettingsViewModel.shared.pendingRestoreActivitySeen,
            "a failed marking pass must keep the restore suppression, or replayed txs pop a sheet"
        )
    }

    func testMarkingPassIsSkippedWhenNoRestoreIsPending() async {
        SettingsViewModel.shared.pendingRestoreActivitySeen = false
        let app = AppViewModel()
        var didRunPass = false

        await app.completePendingRestoreActivitySeen {
            didRunPass = true
            return true
        }

        XCTAssertFalse(didRunPass, "every on-chain sync would re-mark all activities seen")
        XCTAssertFalse(SettingsViewModel.shared.pendingRestoreActivitySeen)
    }
}
