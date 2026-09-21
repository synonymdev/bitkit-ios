@testable import Bitkit
import XCTest

final class ChannelMigrationPersistenceTests: XCTestCase {
    private enum SetupError: Error {
        case failed
    }

    private let migrations = MigrationsService.shared

    override func setUp() {
        super.setUp()
        migrations.pendingChannelMigration = nil
    }

    override func tearDown() {
        migrations.pendingChannelMigration = nil
        super.tearDown()
    }

    func testPendingMigrationIsRetainedWhenSetupFails() async {
        let migration = makeMigration(seed: 1)
        migrations.pendingChannelMigration = migration

        do {
            try await migrations.withPendingChannelMigration { pendingMigration in
                XCTAssertEqual(pendingMigration, migration)
                throw SetupError.failed
            }
            XCTFail("Expected setup to fail")
        } catch SetupError.failed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(migrations.pendingChannelMigration, migration)
    }

    func testPendingMigrationIsClearedAfterSetupSucceeds() async {
        let migration = makeMigration(seed: 2)
        migrations.pendingChannelMigration = migration

        await migrations.withPendingChannelMigration { pendingMigration in
            XCTAssertEqual(pendingMigration, migration)
        }

        XCTAssertNil(migrations.pendingChannelMigration)
    }

    func testNewPendingMigrationIsNotClearedAfterSetupSucceeds() async {
        let migration = makeMigration(seed: 3)
        let replacement = makeMigration(seed: 4)
        migrations.pendingChannelMigration = migration

        await migrations.withPendingChannelMigration { pendingMigration in
            XCTAssertEqual(pendingMigration, migration)
            migrations.pendingChannelMigration = replacement
        }

        XCTAssertEqual(migrations.pendingChannelMigration, replacement)
    }

    private func makeMigration(seed: UInt8) -> PendingChannelMigration {
        PendingChannelMigration(
            channelManager: Data([seed]),
            channelMonitors: [Data([seed, seed &+ 1])]
        )
    }
}
