@testable import Bitkit
import XCTest

@MainActor
final class RNMigrationRetryScheduleTests: XCTestCase {
    func testBackoffSurvivesReloadAndStopsSyncFrequencyRetries() throws {
        let suite = "RNMigrationBackoff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1000)
        let service = Bitkit.MigrationsService(userDefaults: defaults, now: { now })
        service.pendingMetadata = Bitkit.RNMetadata(tags: ["missing": ["retained"]])
        XCTAssertTrue(service.shouldRetryPendingMigrationData)
        service.recordPendingMigrationRetry()

        for _ in 0 ..< 5 {
            now.addTimeInterval(10)
            XCTAssertFalse(service.shouldRetryPendingMigrationData)
        }
        let reloaded = Bitkit.MigrationsService(userDefaults: defaults, now: { now })
        XCTAssertFalse(reloaded.shouldRetryPendingMigrationData)
        XCTAssertEqual(reloaded.pendingMetadata?.tags, ["missing": ["retained"]])
        now.addTimeInterval(10)
        XCTAssertTrue(reloaded.shouldRetryPendingMigrationData)
        reloaded.recordPendingMigrationRetry()
        now.addTimeInterval(119)
        XCTAssertFalse(service.shouldRetryPendingMigrationData)
        now.addTimeInterval(1)
        XCTAssertTrue(service.shouldRetryPendingMigrationData)
    }

    func testRetriesReachHourlyCapWithoutDroppingMarkersAndRecoverLateTags() async throws {
        let suite = "RNMigrationBackoffRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1000)
        let service = Bitkit.MigrationsService(userDefaults: defaults, now: { now })
        service.pendingMetadata = Bitkit.RNMetadata(tags: ["late": ["retained"]])
        for delay in [60.0, 120, 240, 480, 960, 1920, 3600, 3600] {
            XCTAssertTrue(service.shouldRetryPendingMigrationData)
            service.recordPendingMigrationRetry()
            now.addTimeInterval(delay - 1)
            XCTAssertFalse(service.shouldRetryPendingMigrationData)
            now.addTimeInterval(1)
            XCTAssertTrue(service.shouldRetryPendingMigrationData)
            XCTAssertEqual(service.pendingMetadata?.tags, ["late": ["retained"]])
        }
        var applied: [String: [String]] = [:]
        await service.retryPendingMetadata { tags in
            applied = tags
            return []
        }
        service.recordPendingMigrationRetry()
        XCTAssertEqual(applied, ["late": ["retained"]])
        XCTAssertFalse(service.hasPendingMigrationRetries)
        XCTAssertNil(defaults.data(forKey: "rnMigrationRetrySchedule"))
        service.pendingRemoteTransfers = ["new-transfer": "channel"]
        XCTAssertTrue(service.shouldRetryPendingMigrationData, "a completed schedule must not delay newly pending data")
    }

    func testClockRollbackDoesNotStarveRetries() throws {
        let suite = "RNMigrationBackoffClock.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1000)
        let service = Bitkit.MigrationsService(userDefaults: defaults, now: { now })
        service.pendingRemoteTransfers = ["transfer": "channel"]
        service.recordPendingMigrationRetry()
        XCTAssertFalse(service.shouldRetryPendingMigrationData)
        now.addTimeInterval(-1)
        XCTAssertTrue(service.shouldRetryPendingMigrationData)
        service.recordPendingMigrationRetry()
        XCTAssertFalse(service.shouldRetryPendingMigrationData)
    }
}
