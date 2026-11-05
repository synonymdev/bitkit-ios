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
}
