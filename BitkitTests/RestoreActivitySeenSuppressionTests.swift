@testable import Bitkit
import XCTest

/// Regression cover for #588: the post-restore received-sheet suppression must outlive the pass that
/// marks the replayed activities as seen, and that pass must not sweep up payments that arrive while
/// the restore is still running.
///
/// Clearing `pendingRestoreActivitySeenSince` up front reopened
/// `presentReceivedSheetForOnchainTransaction` while the marking pass was still running — and kept it
/// open when the pass failed — so a historical tx replayed by LDK could pop a "Received" sheet.
@MainActor
final class RestoreActivitySeenSuppressionTests: XCTestCase {
    private let flagKey = "pendingRestoreActivitySeenSince"
    private let restoreStartedAt: UInt64 = 1_700_000_000

    override func setUp() {
        super.setUp()
        snapshotAppDefaults(flagKey)
    }

    func testSuppressionHoldsUntilTheMarkingPassFinishes() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()
        var flagDuringPass: Bool?

        await app.completePendingRestoreActivitySeen { _ in
            flagDuringPass = SettingsViewModel.shared.pendingRestoreActivitySeen
            return true
        }

        XCTAssertEqual(flagDuringPass, true, "suppression was lifted before the activities were marked seen")
        XCTAssertFalse(SettingsViewModel.shared.pendingRestoreActivitySeen)
    }

    func testSuppressionIsKeptWhenTheMarkingPassFails() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()

        await app.completePendingRestoreActivitySeen { _ in false }

        XCTAssertTrue(
            SettingsViewModel.shared.pendingRestoreActivitySeen,
            "a failed marking pass must keep the restore suppression, or replayed txs pop a sheet"
        )
    }

    func testMarkingPassIsSkippedWhenNoRestoreIsPending() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = 0
        let app = AppViewModel()
        var didRunPass = false

        await app.completePendingRestoreActivitySeen { _ in
            didRunPass = true
            return true
        }

        XCTAssertFalse(didRunPass, "every on-chain sync would re-mark all activities seen")
        XCTAssertFalse(SettingsViewModel.shared.pendingRestoreActivitySeen)
    }

    /// The sweep is bounded by when the restore began, so a payment that genuinely arrives mid-restore
    /// keeps its unseen state instead of being marked seen along with the replayed history.
    func testMarkingPassIsBoundedByTheRestoreStartTime() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()
        var passedCutoff: UInt64?

        await app.completePendingRestoreActivitySeen { cutoff in
            passedCutoff = cutoff
            return true
        }

        XCTAssertEqual(passedCutoff, restoreStartedAt)
    }

    /// The suppression is armed as the restore starts, not on the Get Started tap, because startup
    /// sync begins as soon as the wallet exists.
    func testSuppressionFlagIsDerivedFromTheStoredStartTime() {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        XCTAssertTrue(SettingsViewModel.shared.pendingRestoreActivitySeen)
        XCTAssertEqual(SettingsViewModel.shared.pendingRestoreActivitySeenSince, restoreStartedAt)

        SettingsViewModel.shared.pendingRestoreActivitySeenSince = 0
        XCTAssertFalse(SettingsViewModel.shared.pendingRestoreActivitySeen)
    }
}
