@testable import Bitkit
import XCTest

@MainActor
final class ArkadeExitBackupTests: XCTestCase {
    private let walletIndex = 99

    override func tearDown() {
        try? FileManager.default.removeItem(at: Env.arkadeExitRestore(walletIndex: walletIndex))
        try? FileManager.default.removeItem(at: Env.arkadeStartedMarker(walletIndex: walletIndex))
        super.tearDown()
    }

    func testUploadsTheExportedWalletDataUnderItsOwnKey() async throws {
        let suite = "ArkadeExitBackupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = ArkadeExitBackupV1(createdAt: 1000, network: "mutinynet", exitState: "{\"version\":1}")
        var uploads: [(String, Data)] = []
        let service = BackupService(
            defaults: defaults,
            backupData: { _ in try JSONEncoder().encode(backup) },
            uploadBackup: { uploads.append(($0, $1)) }
        )

        await service.triggerBackup(category: .arkadeExit)

        let upload = try XCTUnwrap(uploads.first)
        XCTAssertEqual(upload.0, "ARKADE_EXIT")
        let restored = try JSONDecoder().decode(ArkadeExitBackupV1.self, from: upload.1)
        XCTAssertEqual(restored.exitState, backup.exitState)
        XCTAssertEqual(restored.network, backup.network)
    }

    func testReadsABackupWithoutAVersion() throws {
        let json = Data(#"{"createdAt":1000,"network":"bitcoin","exitState":"state"}"#.utf8)

        let backup = try JSONDecoder().decode(ArkadeExitBackupV1.self, from: json)

        XCTAssertEqual(backup.version, 1)
        XCTAssertEqual(backup.exitState, "state")
    }

    func testStagesARestoredBackupForTheNextStartAndScansAgain() async throws {
        let network = try XCTUnwrap(ArkadeManager.config?.network)
        let marker = Env.arkadeStartedMarker(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: marker)
        let backup = ArkadeExitBackupV1(createdAt: 1000, network: network, exitState: "state")

        try await ArkadeManager.shared.restoreExitBackup(backup, walletIndex: walletIndex)

        let staged = try String(contentsOf: Env.arkadeExitRestore(walletIndex: walletIndex), encoding: .utf8)
        XCTAssertEqual(staged, "state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSkipsABackupFromAnotherNetwork() async throws {
        let backup = ArkadeExitBackupV1(createdAt: 1000, network: "testnet", exitState: "state")

        try await ArkadeManager.shared.restoreExitBackup(backup, walletIndex: walletIndex)

        XCTAssertFalse(FileManager.default.fileExists(atPath: Env.arkadeExitRestore(walletIndex: walletIndex).path))
    }
}
