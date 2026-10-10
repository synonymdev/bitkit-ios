@testable import Bitkit
import BitkitCore
import XCTest

final class RNMigrationTagRetentionTests: XCTestCase {
    func testTransferAndBoostMarkersSurviveMissingActivitiesAndReload() async throws {
        let suite = "RNMigrationMarkers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MigrationsService(userDefaults: defaults)
        service.pendingRemoteTransfers = ["transfer": "channel"]
        service.pendingRemoteBoosts = ["parent": "child"]
        var activities: [String: OnchainActivity] = [:]
        let get: (String) async -> OnchainActivity? = { activities[$0] }
        let update: (OnchainActivity) async throws -> Void = { activities[$0.txId] = $0 }
        let transfers: ([String: String]) async -> [String: String] = {
            await service.applyRemoteTransfers($0, getActivity: get, updateActivity: update)
        }
        let boosts: ([String: String]) async -> [String: String] = {
            await service.applyBoostTransactions($0, getActivity: get, updateActivity: update)
        }

        await service.reapplyMetadataAfterSync(includeLocalMetadata: false, applyTransfers: transfers, applyBoosts: boosts)
        XCTAssertEqual(service.pendingRemoteTransfers, ["transfer": "channel"])
        XCTAssertEqual(service.pendingRemoteBoosts, ["parent": "child"])
        XCTAssertFalse(service.canCleanupAfterMigration)
        XCTAssertFalse(service.needsPostMigrationSync)

        let reloaded = MigrationsService(userDefaults: defaults)
        for id in ["transfer", "parent", "child"] {
            activities[id] = onchain(id: id)
        }
        await reloaded.reapplyMetadataAfterSync(includeLocalMetadata: false, applyTransfers: transfers, applyBoosts: boosts)
        XCTAssertNil(reloaded.pendingRemoteTransfers)
        XCTAssertNil(reloaded.pendingRemoteBoosts)
        XCTAssertTrue(reloaded.canCleanupAfterMigration)
        XCTAssertEqual(activities["transfer"]?.channelId, "channel")
        XCTAssertEqual(activities["transfer"]?.isTransfer, true)
        XCTAssertEqual(activities["parent"]?.boostTxIds, ["child"])
    }

    func testFailedMarkerWritesRemainPending() async {
        let service = MigrationsService()
        let update: (OnchainActivity) async throws -> Void = { _ in throw NSError(domain: "test", code: 1) }
        let transfer = ["transfer": "channel"]
        let boost = ["parent": "child"]
        let pendingTransfers = await service.applyRemoteTransfers(transfer, getActivity: { self.onchain(id: $0) }, updateActivity: update)
        let pendingBoosts = await service.applyBoostTransactions(boost, getActivity: { self.onchain(id: $0) }, updateActivity: update)
        XCTAssertEqual(pendingTransfers, transfer)
        XCTAssertEqual(pendingBoosts, boost)
    }

    private func onchain(id: String) -> OnchainActivity {
        OnchainActivity(
            walletId: "wallet0", id: id, txType: .received, txId: id,
            value: 1000, fee: 0, feeRate: 1, address: "", confirmed: true,
            timestamp: 1, isBoosted: false, boostTxIds: [], isTransfer: false,
            doesExist: true, confirmTimestamp: nil, channelId: nil, transferTxId: nil,
            contact: nil, createdAt: nil, updatedAt: nil, seenAt: nil
        )
    }

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
