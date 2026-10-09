@testable import Bitkit
import BitkitCore
import XCTest

final class RNMigrationTagRetentionTests: XCTestCase {
    func testTwoSyncsRetainMissingTagsWithoutReplayingAppliedTags() async throws {
        let suite = "RNMigrationTagRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MigrationsService(userDefaults: defaults)
        service.pendingMetadata = RNMetadata(tags: ["known": ["sent"], "missing": ["received"]])
        var activities = Set(["known"])
        var writes: [String] = []
        let apply: ([String: [String]]) async -> Set<String> = { tags in
            await service.applyPendingTags(tags, resolveActivityId: { id in
                activities.contains(id) ? id : nil
            }, upsertTags: { tags in
                writes.append(contentsOf: tags.map(\.activityId))
            })
        }

        await service.reapplyMetadataAfterSync(includeLocalMetadata: false, applyTags: apply)
        XCTAssertEqual(service.pendingMetadata?.tags, ["missing": ["received"]])
        XCTAssertFalse(service.canCleanupAfterMigration)
        XCTAssertTrue(service.hasPendingMigrationRetries)
        XCTAssertFalse(service.needsPostMigrationSync)
        XCTAssertEqual(writes, ["known"])

        let reloaded = MigrationsService(userDefaults: defaults)
        XCTAssertEqual(reloaded.pendingMetadata?.tags, ["missing": ["received"]])
        activities.insert("missing")
        await reloaded.reapplyMetadataAfterSync(includeLocalMetadata: false, applyTags: apply)
        XCTAssertNil(reloaded.pendingMetadata)
        XCTAssertTrue(reloaded.canCleanupAfterMigration)
        XCTAssertFalse(reloaded.hasPendingMigrationRetries)
        XCTAssertEqual(writes, ["known", "missing"])
    }

    func testFailedTagWriteStaysPending() async throws {
        let suite = "RNMigrationTagRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MigrationsService(userDefaults: defaults)
        service.pendingMetadata = RNMetadata(tags: ["known": ["sent"]])
        await service.retryPendingMetadata { tags in
            await service.applyPendingTags(tags, resolveActivityId: { $0 }, upsertTags: { _ in
                throw NSError(domain: "test", code: 1)
            })
        }
        XCTAssertEqual(service.pendingMetadata?.tags, ["known": ["sent"]])
        XCTAssertFalse(service.canCleanupAfterMigration)
    }

    func testKeepsOnlyTagsWhoseActivityIsMissing() {
        let metadata = RNMetadata(
            tags: ["known": ["sent"], "missing": ["received"]],
            lastUsedTags: ["sent"]
        )

        let remaining = rnMetadataRetainingUnappliedTags(metadata, unappliedActivityIds: ["missing"])

        XCTAssertEqual(remaining?.tags, ["missing": ["received"]])
        XCTAssertNil(remaining?.lastUsedTags)
    }

    func testDropsMetadataWhenEveryTagApplied() {
        let metadata = RNMetadata(tags: ["known": ["sent"]], lastUsedTags: ["sent"])

        XCTAssertNil(rnMetadataRetainingUnappliedTags(metadata, unappliedActivityIds: []))
    }

    func testDropsMetadataWhenThereAreNoTags() {
        let metadata = RNMetadata(tags: nil, lastUsedTags: ["sent"])

        XCTAssertNil(rnMetadataRetainingUnappliedTags(metadata, unappliedActivityIds: ["missing"]))
    }
}
