@testable import Bitkit
import XCTest

@MainActor
final class SparkExitBackupTests: XCTestCase {
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

    func testAnUnreadableRemoteExitBackupBacksOffInsteadOfRetryingEveryFewSeconds() async throws {
        let suite = "SparkExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let export = try JSONEncoder().encode(SparkExitBackupV1(version: 1, createdAt: 1000, network: "regtest", exitState: "fresh"))
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in export },
            uploadBackup: { _, _ in },
            fetchBackup: { _ in Data("not an exit backup".utf8) }
        )

        await service.restoreSparkExit()
        let outcome = await service.triggerBackup(category: .sparkExit)

        XCTAssertEqual(outcome, .temporarilyUnavailable)
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
}
