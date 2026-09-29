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
    private let heightKey = "restoreSyncedBlockHeight"
    private let syncedHeight: UInt32 = 900
    private let restoreStartedAt: UInt64 = 1_700_000_000

    override func setUp() {
        super.setUp()
        snapshotAppDefaults(flagKey, heightKey)
    }

    func testSuppressionHoldsUntilTheMarkingPassFinishes() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()
        var flagDuringPass: Bool?

        await app.completePendingRestoreActivitySeen(syncedBlockHeight: syncedHeight) { _ in
            flagDuringPass = SettingsViewModel.shared.pendingRestoreActivitySeen
            return true
        }

        XCTAssertEqual(flagDuringPass, true, "suppression was lifted before the activities were marked seen")
        XCTAssertFalse(SettingsViewModel.shared.pendingRestoreActivitySeen)
    }

    func testSuppressionIsKeptWhenTheMarkingPassFails() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()

        await app.completePendingRestoreActivitySeen(syncedBlockHeight: syncedHeight) { _ in false }

        XCTAssertTrue(
            SettingsViewModel.shared.pendingRestoreActivitySeen,
            "a failed marking pass must keep the restore suppression, or replayed txs pop a sheet"
        )
    }

    func testMarkingPassIsSkippedWhenNoRestoreIsPending() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = 0
        let app = AppViewModel()
        var didRunPass = false

        await app.completePendingRestoreActivitySeen(syncedBlockHeight: syncedHeight) { _ in
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

        await app.completePendingRestoreActivitySeen(syncedBlockHeight: syncedHeight) { cutoff in
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

    /// A rescan after the hold replays confirmations for the same history, so the restore tip must
    /// outlive the hold. Android #1342.
    func testCompletingTheHoldRecordsTheRestoreTip() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        SettingsViewModel.shared.restoreSyncedBlockHeight = 0
        let app = AppViewModel()

        await app.completePendingRestoreActivitySeen(syncedBlockHeight: syncedHeight) { _ in true }

        XCTAssertEqual(SettingsViewModel.shared.restoreSyncedBlockHeight, syncedHeight)
    }

    func testFailedPassDoesNotRecordTheRestoreTip() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        SettingsViewModel.shared.restoreSyncedBlockHeight = 0
        let app = AppViewModel()

        await app.completePendingRestoreActivitySeen(syncedBlockHeight: syncedHeight) { _ in false }

        XCTAssertEqual(SettingsViewModel.shared.restoreSyncedBlockHeight, 0)
    }

    /// A receive arriving while the sweep runs is held and presented once the hold lifts.
    func testReceivesHeldDuringTheSweepArePresentedOnceTheHoldLifts() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()
        XCTAssertTrue(app.beginCompletingPendingRestoreActivitySeen())

        XCTAssertTrue(app.holdReceiveDuringRestore(txid: "a", amountSats: 1000))
        XCTAssertTrue(app.holdReceiveDuringRestore(txid: "b", amountSats: 2000))
        XCTAssertTrue(app.holdReceiveDuringRestore(txid: "a", amountSats: 1000))
        XCTAssertTrue(app.holdReceiveDuringRestore(txid: "c", amountSats: 0))

        var presented: [String] = []
        await app.completePendingRestoreActivitySeen(
            syncedBlockHeight: syncedHeight,
            markAllSeen: { _ in true },
            presentReceive: { txid, _ in presented.append(txid) }
        )

        XCTAssertEqual(presented, ["a", "b"])
        XCTAssertTrue(app.restoreHeldReceives.isEmpty)
    }

    /// The restore scan cannot tell a payment arriving mid-scan from an unconfirmed one it replays,
    /// so whatever it emitted is dropped as history once its sync completes.
    func testReceivesHeldDuringTheRestoreScanAreDropped() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()
        app.holdReceiveDuringRestore(txid: "replayed", amountSats: 1000)

        XCTAssertTrue(app.beginCompletingPendingRestoreActivitySeen())
        XCTAssertTrue(app.restoreHeldReceives.isEmpty)

        var presented: [String] = []
        await app.completePendingRestoreActivitySeen(
            syncedBlockHeight: syncedHeight,
            markAllSeen: { _ in true },
            presentReceive: { txid, _ in presented.append(txid) }
        )

        XCTAssertTrue(presented.isEmpty, "an unconfirmed pre-restore receive would pop a Received sheet")
    }

    /// A confirmation handled while the sweep runs is judged against the restore tip on replay.
    func testConfirmationsHeldDuringTheSweepAreCheckedAgainstTheRestoreTip() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()
        XCTAssertTrue(app.beginCompletingPendingRestoreActivitySeen())
        let now = UInt64(Date().timeIntervalSince1970)

        app.holdReceiveDuringRestore(txid: "old", amountSats: 1000, blockHeight: syncedHeight, confirmationTime: now)
        app.holdReceiveDuringRestore(txid: "new", amountSats: 1000, blockHeight: syncedHeight + 1, confirmationTime: now)

        var presented: [String] = []
        await app.completePendingRestoreActivitySeen(
            syncedBlockHeight: syncedHeight,
            markAllSeen: { _ in true },
            presentReceive: { txid, _ in presented.append(txid) }
        )

        XCTAssertEqual(presented, ["new"])
    }

    /// Only the first sync after the restore sweeps, so a later one cannot raise the recorded tip.
    func testOnlyOneSweepRunsAtATime() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()

        XCTAssertTrue(app.beginCompletingPendingRestoreActivitySeen())
        XCTAssertFalse(app.beginCompletingPendingRestoreActivitySeen())

        await app.completePendingRestoreActivitySeen(syncedBlockHeight: syncedHeight) { _ in false }

        XCTAssertTrue(app.beginCompletingPendingRestoreActivitySeen(), "a failed sweep must let the next sync retry")
    }

    func testHeldReceivesWaitWhenThePassFails() async {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = restoreStartedAt
        let app = AppViewModel()
        XCTAssertTrue(app.beginCompletingPendingRestoreActivitySeen())
        app.holdReceiveDuringRestore(txid: "a", amountSats: 1000)

        var presented: [String] = []
        await app.completePendingRestoreActivitySeen(
            syncedBlockHeight: syncedHeight,
            markAllSeen: { _ in false },
            presentReceive: { txid, _ in presented.append(txid) }
        )

        XCTAssertTrue(presented.isEmpty, "a held receive shown before the sweep could be replayed history")
        XCTAssertEqual(app.restoreHeldReceives.map(\.txid), ["a"])
    }

    func testReceivesAreNotHeldWithoutARestore() {
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = 0
        let app = AppViewModel()

        XCTAssertFalse(app.holdReceiveDuringRestore(txid: "a", amountSats: 1000))
        XCTAssertFalse(app.beginCompletingPendingRestoreActivitySeen())
        XCTAssertTrue(app.restoreHeldReceives.isEmpty)
    }
}
