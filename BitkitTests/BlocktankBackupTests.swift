@testable import Bitkit
import BitkitCore
import SQLite3
import XCTest

@MainActor
final class BlocktankBackupTests: XCTestCase {
    private var databaseDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        _ = Bitkit.CoreService.shared.blocktank
        await drainCoreServiceQueue()
        databaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlocktankBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        _ = try initDb(basePath: databaseDirectory.path)
        try await Bitkit.CoreService.shared.blocktank.upsertOrdersList([.mock(id: "cached-order")])
    }

    override func tearDown() async throws {
        await drainCoreServiceQueue()
        await repointCoreToAppStorage()
        if let databaseDirectory {
            try FileManager.default.removeItem(at: databaseDirectory)
        }
        try await super.tearDown()
    }

    func testAbsentCachedInfoDoesNotPreventCompleteCachedBackup() async throws {
        let defaults = try makeIsolatedDefaults()
        var uploads: [Data] = []
        let service = BackupService(defaults: defaults, uploadBackup: { key, data in
            XCTAssertEqual(key, BackupCategory.blocktank.rawValue)
            uploads.append(data)
        })

        let outcome = await service.triggerBackup(category: .blocktank)
        XCTAssertTrue(outcome == .completed)
        XCTAssertEqual(uploads.count, 1)
        let payload = try JSONDecoder().decode(BlocktankBackupV1.self, from: XCTUnwrap(uploads.first))
        XCTAssertEqual(payload.orders.map(\.id), ["cached-order"])
        XCTAssertTrue(payload.cjitEntries.isEmpty)
        XCTAssertNil(payload.info)
        XCTAssertFalse(service.getBackupStatus(category: .blocktank).isRequired)
        await service.stopObservingBackups()
    }

    func testUnreadableCachedDataPreservesAcknowledgedBackupAndPendingRevision() async throws {
        for table in ["orders", "cjit_entries", "info"] {
            let defaults = try makeIsolatedDefaults(table)
            var uploads: [Data] = []
            let service = BackupService(defaults: defaults, uploadBackup: { _, data in
                uploads.append(data)
            })
            let initial = await service.triggerBackup(category: .blocktank)
            XCTAssertTrue(initial == .completed, table)
            let acknowledged = try XCTUnwrap(uploads.last)
            let synced = service.getBackupStatus(category: .blocktank).synced
            service.markBackupRequired(category: .blocktank, schedule: false)
            let pending = service.getBackupStatus(category: .blocktank)
            XCTAssertTrue(pending.isRequired, table)

            try execute("ALTER TABLE \(table) RENAME TO unreadable_\(table)")
            let failed = await service.triggerBackup(category: .blocktank)
            XCTAssertTrue(failed == .failed, table)
            XCTAssertEqual(uploads, [acknowledged], table)
            let afterFailure = service.getBackupStatus(category: .blocktank)
            XCTAssertEqual(afterFailure.synced, synced, table)
            XCTAssertEqual(afterFailure.required, pending.required, table)
            XCTAssertTrue(afterFailure.isRequired, table)
            XCTAssertFalse(afterFailure.running, table)

            try execute("ALTER TABLE unreadable_\(table) RENAME TO \(table)")
            let recovered = await service.triggerBackup(category: .blocktank)
            XCTAssertTrue(recovered == .completed, table)
            XCTAssertEqual(uploads.count, 2, table)
            XCTAssertFalse(service.getBackupStatus(category: .blocktank).isRequired, table)
            await service.stopObservingBackups()
        }
    }

    private func execute(_ sql: String) throws {
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(databaseDirectory.appendingPathComponent("blocktank.db").path,
                                     &connection, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(connection) }
        guard opened == SQLITE_OK, sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "BlocktankBackupTests", code: Int(sqlite3_errcode(connection)))
        }
    }
}
