@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

@MainActor
final class RNMigrationSyncLifecycleTests: XCTestCase {
    private final class Gate {
        let entered = XCTestExpectation(description: "migration operation suspended")
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testWipeDuringTagLookupDoesNotWriteOrResurrectOldMetadata() async throws {
        let suite = "RNMigrationWipe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let migrations = Bitkit.MigrationsService(userDefaults: defaults)
        migrations.pendingMetadata = Bitkit.RNMetadata(tags: ["old": ["old-tag"]], lastUsedTags: ["old-tag"])
        let gate = Gate()
        var writes = 0
        let task = Task {
            await migrations.retryPendingMetadata { tags in
                await migrations.applyPendingTags(tags, resolveActivityId: { id in
                    await gate.suspend()
                    return id
                }, upsertTags: { _ in writes += 1 })
            }
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        migrations.invalidatePendingRetries()
        defaults.removePersistentDomain(forName: suite)
        migrations.pendingMetadata = Bitkit.RNMetadata(tags: ["new-wallet": ["new-tag"]])
        gate.resume()
        await task.value

        XCTAssertEqual(writes, 0)
        XCTAssertNil(defaults.array(forKey: "lastUsedTags"))
        XCTAssertEqual(migrations.pendingMetadata?.tags, ["new-wallet": ["new-tag"]])
        XCTAssertEqual(Bitkit.MigrationsService(userDefaults: defaults).pendingMetadata?.tags, ["new-wallet": ["new-tag"]])
    }

    func testWipeDuringTransferLookupDoesNotWriteOrResurrectMarkers() async throws {
        try await assertMarkerLookupInvalidated(isBoost: false)
    }

    func testWipeDuringBoostLookupDoesNotWriteOrResurrectMarkers() async throws {
        try await assertMarkerLookupInvalidated(isBoost: true)
    }

    private func assertMarkerLookupInvalidated(isBoost: Bool) async throws {
        let suite = "RNMigrationMarkerWipe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let migrations = Bitkit.MigrationsService(userDefaults: defaults)
        if isBoost {
            migrations.pendingRemoteBoosts = ["parent": "child"]
        } else {
            migrations.pendingRemoteTransfers = ["transfer": "channel"]
        }
        let gate = Gate()
        var writes = 0
        let get: (String) async -> OnchainActivity? = { id in
            await gate.suspend()
            return self.onchain(id: id)
        }
        let update: (OnchainActivity) async throws -> Void = { _ in writes += 1 }
        let task = Task {
            await migrations.reapplyMetadataAfterSync(
                includeLocalMetadata: false,
                applyTransfers: { await migrations.applyRemoteTransfers($0, getActivity: get, updateActivity: update) },
                applyBoosts: { await migrations.applyBoostTransactions($0, getActivity: get, updateActivity: update) }
            )
        }
        await fulfillment(of: [gate.entered], timeout: 2)
        migrations.invalidatePendingRetries()
        defaults.removePersistentDomain(forName: suite)
        migrations.pendingRemoteTransfers = ["new-transfer": "new-channel"]
        migrations.pendingRemoteBoosts = ["new-parent": "new-child"]
        gate.resume()
        await task.value

        XCTAssertEqual(writes, 0)
        let reloaded = Bitkit.MigrationsService(userDefaults: defaults)
        XCTAssertEqual(reloaded.pendingRemoteTransfers, ["new-transfer": "new-channel"])
        XCTAssertEqual(reloaded.pendingRemoteBoosts, ["new-parent": "new-child"])
    }

    func testOverlappingSyncEventsCompleteOnceAndBackgroundRetryLeavesNewReceiveUnseen() async throws {
        snapshotAppDefaults("pendingRestoreActivitySeenSince", "pendingRestoreAddressTypePrune")
        SettingsViewModel.shared.pendingRestoreActivitySeenSince = 0
        SettingsViewModel.shared.pendingRestoreAddressTypePrune = false
        let suite = "RNMigrationCompletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let migrations = Bitkit.MigrationsService(userDefaults: defaults)
        migrations.needsPostMigrationSync = true
        migrations.isShowingMigrationLoading = true
        migrations.isRestoringFromRNRemoteBackup = true
        migrations.pendingMetadata = Bitkit.RNMetadata(tags: ["missing": ["retained"]])
        let gate = Gate()
        var syncCount = 0
        var sweepCount = 0
        var localPasses: [Bool] = []
        var seen = ["history": false]
        let operations = PostMigrationSyncOperations(
            syncPayments: {
                syncCount += 1
                if syncCount == 1 { await gate.suspend() }
            },
            markActivitiesSeen: {
                sweepCount += 1
                for id in seen.keys {
                    seen[id] = true
                }
            },
            reapplyMetadata: { includeLocal in
                localPasses.append(includeLocal)
                await migrations.reapplyMetadataAfterSync(includeLocalMetadata: includeLocal, applyTags: { Set($0.keys) })
            }
        )
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel(),
            migrations: migrations, postMigrationSyncOperations: operations
        )
        let event = Event.syncCompleted(syncType: .onchainWallet, syncedBlockHeight: 1)
        app.handleLdkNodeEvent(event)
        let completion = try XCTUnwrap(app.postMigrationSyncTask)
        app.handleLdkNodeEvent(event)
        await fulfillment(of: [gate.entered], timeout: 2)
        app.handleLdkNodeEvent(event)
        XCTAssertEqual(syncCount, 1)
        XCTAssertTrue(migrations.needsPostMigrationSync)
        gate.resume()
        await completion.value

        XCTAssertEqual(sweepCount, 1)
        XCTAssertEqual(seen["history"], true)
        XCTAssertFalse(migrations.needsPostMigrationSync)
        XCTAssertFalse(migrations.isShowingMigrationLoading)
        XCTAssertFalse(migrations.isRestoringFromRNRemoteBackup)
        XCTAssertTrue(migrations.hasPendingMigrationRetries)
        XCTAssertTrue(AppViewModel.shouldPresentConfirmedOnlyReceive(
            confirmationTime: UInt64(Date().timeIntervalSince1970), blockHeight: 2,
            isMigrating: migrations.isShowingMigrationLoading || migrations.needsPostMigrationSync,
            restoreSyncedBlockHeight: 0
        ))

        seen["new-receive"] = false
        app.handleLdkNodeEvent(event)
        let retry = try XCTUnwrap(app.postMigrationSyncTask)
        await retry.value
        XCTAssertEqual(syncCount, 2)
        XCTAssertEqual(sweepCount, 1)
        XCTAssertEqual(localPasses, [true, false])
        XCTAssertEqual(seen["new-receive"], false)
    }

    func testResetDrainsAnInFlightWriteAndBlocksFurtherSyncEvents() async throws {
        let suite = "RNMigrationDrain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let migrations = Bitkit.MigrationsService(userDefaults: defaults)
        migrations.needsPostMigrationSync = true
        let gate = Gate()
        var finishedWrite = false
        var resetReturned = false
        var reapplyCount = 0
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel(),
            migrations: migrations, postMigrationSyncOperations: PostMigrationSyncOperations(
                syncPayments: {}, markActivitiesSeen: {}, reapplyMetadata: { _ in
                    reapplyCount += 1
                    await gate.suspend()
                    finishedWrite = true
                }
            )
        )
        let event = Event.syncCompleted(syncType: .onchainWallet, syncedBlockHeight: 1)
        app.handleLdkNodeEvent(event)
        await fulfillment(of: [gate.entered], timeout: 2)
        let reset = Task {
            await app.cancelMigrationSyncForWipe()
            XCTAssertTrue(finishedWrite, "reset must drain existing writes before wiping storage")
            resetReturned = true
        }
        while app.postMigrationSyncTask?.isCancelled == false {
            await Task.yield()
        }
        XCTAssertFalse(resetReturned)
        app.handleLdkNodeEvent(event)
        gate.resume()
        await reset.value
        XCTAssertTrue(resetReturned)
        XCTAssertTrue(migrations.needsPostMigrationSync, "the cancelled pass must not alter completion state")
        XCTAssertEqual(reapplyCount, 1)
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
}
