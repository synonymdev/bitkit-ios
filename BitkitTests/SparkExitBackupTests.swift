@testable import Bitkit
import BreezSdkSpark
import CryptoKit
import XCTest

@MainActor
final class SparkExitBackupTests: XCTestCase {
    func testAnExitBackupNamesTheNetworkAsSparkDoes() {
        XCTAssertEqual(SparkManager.exitBackupNetworkName(.bitcoin), "mainnet")
        XCTAssertEqual(SparkManager.exitBackupNetworkName(.regtest), "\(BreezSdkSpark.Network.regtest)")
    }

    private let walletIndex = 99

    override func tearDown() {
        try? FileManager.default.removeItem(at: Env.sparkExitRestore(walletIndex: walletIndex))
        super.tearDown()
    }

    func testUploadsTheExportedExitStateUnderItsOwnKey() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "{\"pedigrees\":[]}")
        var uploads: [(String, Data)] = []
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in try JSONEncoder().encode(backup) },
            uploadBackup: { uploads.append(($0, $1)) }
        )

        await service.triggerBackup(category: .sparkExit)

        let upload = try XCTUnwrap(uploads.first)
        XCTAssertEqual(upload.0, "SPARK_EXIT")
        let restored = try JSONDecoder().decode(SparkExitBackupV1.self, from: upload.1)
        XCTAssertEqual(restored.exitState, backup.exitState)
        XCTAssertEqual(restored.network, backup.network)
    }

    /// R4: while an exit runs, a fresh export could lack the leaves it moves, so the backup from before it stays.
    func testDoesNotRefreshTheExitDataWhileAnExitRuns() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var uploads: [String] = []
        var exports = 0
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in
                exports += 1
                return Data("{}".utf8)
            },
            isSparkExitActive: { true },
            uploadBackup: { key, _ in uploads.append(key) }
        )

        let outcome = await service.triggerBackup(category: .sparkExit)

        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(exports, 0)
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(service.getBackupStatus(category: .sparkExit).isRequired, "an active exit counted as backed up")
    }

    func testAFailedExitRestoreBlocksReplacingTheRemoteBackupUntilItRecovers() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        var remoteIsReadable = false
        var uploads: [String] = []
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { key, _ in uploads.append(key) },
            waitForTemporaryFailureDelay: { _ in },
            fetchBackup: { _ in
                guard remoteIsReadable else { throw URLError(.notConnectedToInternet) }
                return nil
            }
        )

        await service.restoreSparkExit()
        _ = await service.triggerBackup(category: .sparkExit)
        XCTAssertTrue(uploads.isEmpty, "A fresh export replaced a remote exit backup the restore couldn't read")

        // The next attempt finds no older backup, so the fresh export may go up.
        remoteIsReadable = true
        _ = await service.triggerBackup(category: .sparkExit)
        XCTAssertEqual(uploads, ["SPARK_EXIT"])
    }

    /// Both rules at once: a pending restore during an exit uploads nothing; once the restore completes and the exit
    /// ends, the upload goes through.
    func testAPendingRestoreDuringAnExitUploadsNothingUntilBothClear() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        var remoteIsReadable = false
        var isExiting = true
        var uploads: [String] = []
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            isSparkExitActive: { isExiting },
            uploadBackup: { key, _ in uploads.append(key) },
            waitForTemporaryFailureDelay: { _ in },
            fetchBackup: { _ in
                guard remoteIsReadable else { throw URLError(.notConnectedToInternet) }
                return nil
            }
        )

        await service.restoreSparkExit()
        _ = await service.triggerBackup(category: .sparkExit)
        XCTAssertTrue(uploads.isEmpty, "the restore is pending and an exit runs")

        // The restore completes, but the exit still runs: still nothing.
        remoteIsReadable = true
        _ = await service.triggerBackup(category: .sparkExit)
        XCTAssertTrue(uploads.isEmpty, "an exit still runs")

        isExiting = false
        _ = await service.triggerBackup(category: .sparkExit)
        XCTAssertEqual(uploads, ["SPARK_EXIT"])
    }

    func testAnExitStateSparkHasNotImportedYetBlocksReplacingTheRemoteBackup() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let staged = Env.sparkExitRestore(walletIndex: LightningService.shared.currentWalletIndex)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("restored".utf8).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        var uploads: [String] = []
        let service = BackupService(defaults: defaults, backupData: { _ in export }, uploadBackup: { key, _ in uploads.append(key) })

        _ = await service.triggerBackup(category: .sparkExit)

        XCTAssertTrue(uploads.isEmpty, "A fresh export replaced the remote backup whose exit data Spark hasn't imported")
    }

    func testAnUnreachableRemoteExitBackupBacksOffInsteadOfRetryingEveryFewSeconds() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { _, _ in },
            fetchBackup: { _ in throw URLError(.notConnectedToInternet) }
        )

        await service.restoreSparkExit()
        let outcome = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(outcome, .temporarilyUnavailable)
    }

    func testAnUnreadableRemoteExitBackupIsSetAsideAndBackupsGoOn() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        let unreadable = Data("{\"version\":2}".utf8)
        var remote = ["SPARK_EXIT": unreadable]
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { remote[$0] = $1 },
            fetchBackup: { remote[$0] },
            importStagedSparkExit: { .nothingStaged }
        )

        await service.restoreSparkExit()
        let outcome = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(remote[BackupService.rejectedSparkExitKey(for: unreadable)], unreadable, "The exit data this app can't read was lost")
        XCTAssertEqual(remote["SPARK_EXIT"], export)
    }

    func testExitDataSparkRejectsIsSetAsideAndBackupsGoOn() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let restored = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 900, network: "regtest", exitState: "newer"))
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        var remote = ["SPARK_EXIT": restored]
        var staged: SparkStagedExitImport = .pending
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { remote[$0] = $1 },
            waitForTemporaryFailureDelay: { _ in },
            fetchBackup: { remote[$0] },
            importStagedSparkExit: { staged },
            discardStagedSparkExit: { _ in staged = .nothingStaged },
            stagedSparkExitState: { "newer" },
            restoreExitBackup: { _ in }
        )

        await service.restoreSparkExit()
        _ = await service.triggerBackup(category: .sparkExit)
        XCTAssertEqual(remote["SPARK_EXIT"], restored, "A transient import failure let a fresh export replace the remote copy")
        XCTAssertFalse(remote.keys.contains { $0.hasPrefix("SPARK_EXIT_REJECTED") })

        staged = .rejected
        let outcome = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(staged, .nothingStaged)
        XCTAssertEqual(remote[BackupService.rejectedSparkExitKey(for: restored)], restored)
        XCTAssertEqual(remote["SPARK_EXIT"], export)
    }

    func testDifferentRejectedCopiesNeverOverwriteEachOther() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        let earlier = Data("earlier".utf8)
        let later = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 900, network: "regtest", exitState: "later"))
        var remote = ["SPARK_EXIT": later, BackupService.rejectedSparkExitKey(for: earlier): earlier]
        var staged: SparkStagedExitImport = .rejected
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { remote[$0] = $1 },
            fetchBackup: { remote[$0] },
            importStagedSparkExit: { staged },
            discardStagedSparkExit: { _ in staged = .nothingStaged },
            stagedSparkExitState: { "later" }
        )

        _ = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(remote[BackupService.rejectedSparkExitKey(for: earlier)], earlier)
        XCTAssertEqual(remote[BackupService.rejectedSparkExitKey(for: later)], later)
        let digest = SHA256.hash(data: later).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(BackupService.rejectedSparkExitKey(for: later), "SPARK_EXIT_REJECTED_" + digest.prefix(16))
        XCTAssertEqual(remote["SPARK_EXIT"], export)
    }

    func testRejectedDataAnotherDeviceReplacedRemotelyIsSetAsideFromTheStagedCopy() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        let otherDevice = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 950, network: "regtest", exitState: "other"))
        var remote = ["SPARK_EXIT": otherDevice]
        var staged: SparkStagedExitImport = .rejected
        var restored: [String] = []
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { remote[$0] = $1 },
            waitForTemporaryFailureDelay: { _ in },
            fetchBackup: { remote[$0] },
            importStagedSparkExit: { staged },
            discardStagedSparkExit: { _ in staged = .nothingStaged },
            stagedSparkExitState: { "mine" },
            restoreExitBackup: { restored.append($0.exitState); staged = .pending }
        )

        _ = await service.triggerBackup(category: .sparkExit)

        let kept = try JSONDecoder().decode(SparkExitBackupV1.self, from: XCTUnwrap(remote.first { $0.key.hasPrefix("SPARK_EXIT_REJECTED_") }?.value))
        XCTAssertEqual(kept.exitState, "mine", "The rejected exit data was lost for another device's backup")
        XCTAssertEqual(kept.network, "regtest")
        XCTAssertEqual(remote["SPARK_EXIT"], otherDevice, "A fresh export replaced exit data another device backed up")
        XCTAssertEqual(restored, ["other"], "The other device's exit data was never restored")
    }

    func testABackupAnotherDeviceWritesWhileAnUnreadableOneIsSetAsideIsRestoredFirst() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let unreadable = Data("unreadable".utf8)
        let otherDevice = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 950, network: "regtest", exitState: "other"))
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        var remote = ["SPARK_EXIT": unreadable]
        var restored: [String] = []
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { key, data in
                remote[key] = data
                // Another device backs up its exit data while this one sets the unreadable copy aside.
                if key.hasPrefix("SPARK_EXIT_REJECTED_") {
                    remote["SPARK_EXIT"] = otherDevice
                }
            },
            waitForTemporaryFailureDelay: { _ in },
            fetchBackup: { remote[$0] },
            importStagedSparkExit: { .nothingStaged },
            restoreExitBackup: { restored.append($0.exitState) }
        )

        await service.restoreSparkExit()
        _ = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(remote[BackupService.rejectedSparkExitKey(for: unreadable)], unreadable)
        XCTAssertEqual(restored, ["other"], "A backup written during the set-aside was replaced unread")
    }

    func testARestoreOfAnotherDevicesBackupIsNotedBeforeTheStagedCopyGoes() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        let otherDevice = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 950, network: "regtest", exitState: "other"))
        var remote = ["SPARK_EXIT": otherDevice]
        var staged: SparkStagedExitImport = .rejected
        var isRestorePendingWhenDiscarded: Bool?
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { remote[$0] = $1 },
            waitForTemporaryFailureDelay: { _ in },
            fetchBackup: { remote[$0] },
            importStagedSparkExit: { staged },
            discardStagedSparkExit: { _ in
                // A stop here relaunches with whatever was saved before the staged copy went.
                isRestorePendingWhenDiscarded = defaults.bool(forKey: "sparkExitRestorePending")
                staged = .nothingStaged
            },
            stagedSparkExitState: { "mine" },
            restoreExitBackup: { _ in staged = .pending }
        )

        _ = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(isRestorePendingWhenDiscarded, true, "A stop after the staged copy went would replace the other device's backup unread")
        XCTAssertEqual(remote["SPARK_EXIT"], otherDevice)
    }

    func testAStagedFileThatCantBeReadKeepsTheRemoteCopy() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        let restored = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 950, network: "regtest", exitState: "restored"))
        var remote = ["SPARK_EXIT": restored]
        struct Unreadable: Error {}
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { remote[$0] = $1 },
            waitForTemporaryFailureDelay: { _ in },
            fetchBackup: { remote[$0] },
            importStagedSparkExit: { .rejected },
            discardStagedSparkExit: { _ in },
            stagedSparkExitState: { throw Unreadable() }
        )

        _ = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(remote["SPARK_EXIT"], restored, "A staged file that couldn't be read let a fresh export replace the remote copy")
    }

    func testOnlyInvalidInputMarksExitDataAsRejected() {
        XCTAssertEqual(SparkStagedExitImport(importError: SdkError.InvalidInput("unsupported exit state version")), .rejected)
        XCTAssertEqual(SparkStagedExitImport(importError: URLError(.notConnectedToInternet)), .pending)
    }

    func testTheLatestBackupTimeSkipsTheExitData() {
        XCTAssertFalse(BackupService.latestBackupTimeCategories.contains(.sparkExit), "Reading the time downloads the exit data")
        XCTAssertTrue(BackupService.latestBackupTimeCategories.contains(.wallet))
    }

    func testStagesARestoredExitStateUntilSparkConnects() async throws {
        guard Env.network == .regtest else { throw XCTSkip("Spark's test network is regtest") }
        let backup = SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "state")

        try await SparkManager.shared.restoreExitBackup(backup, walletIndex: walletIndex)

        let staged = try String(contentsOf: Env.sparkExitRestore(walletIndex: walletIndex), encoding: .utf8)
        XCTAssertEqual(staged, "state")
    }

    func testSkipsAnExitStateFromAnotherNetwork() async throws {
        let backup = SparkExitBackupV1(version: 1, createdAt: 1000, network: "testnet", exitState: "state")

        try await SparkManager.shared.restoreExitBackup(backup, walletIndex: walletIndex)

        XCTAssertFalse(FileManager.default.fileExists(atPath: Env.sparkExitRestore(walletIndex: walletIndex).path))
    }

    func testObservingRestartedOnAForegroundDoesNotMarkTheSameConnectionAgain() {
        var mark = SparkExitBackupMark()

        XCTAssertFalse(mark.claim(version: nil), "Nothing to back up while Spark is disconnected")
        XCTAssertTrue(mark.claim(version: 1))
        XCTAssertFalse(mark.claim(version: 1), "Spark stayed connected while observing restarted")
        XCTAssertTrue(mark.claim(version: 2), "A changed exit state is backed up again")
    }

    func testAnExitStateChangeMissedWhileObservingWasStoppedIsBackedUpOnRestart() {
        var mark = SparkExitBackupMark()
        _ = mark.claim(version: SparkManager.exitStateGeneration)

        // Spark reports a change while the node, and so backup observing, is stopped.
        SparkManager.notifyExitStateChanged()

        XCTAssertTrue(mark.claim(version: SparkManager.exitStateGeneration), "The restart kept the stale exit data backup")
    }

    @MainActor
    func testDiscardingRejectedExitDataKeepsNewerDataStagedMeanwhile() throws {
        let walletIndex = 9901
        let file = Env.sparkExitRestore(walletIndex: walletIndex)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: file)

        SparkManager.shared.discardStagedExitState("rejected", walletIndex: walletIndex)
        XCTAssertEqual(try SparkManager.shared.stagedExitState(walletIndex: walletIndex), "newer")

        SparkManager.shared.discardStagedExitState("newer", walletIndex: walletIndex)
        XCTAssertNil(try SparkManager.shared.stagedExitState(walletIndex: walletIndex))
    }
}
