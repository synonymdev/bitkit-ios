@testable import Bitkit
import Combine
import Paykit
import VssRustClientFfi
import XCTest

@MainActor
final class BackupServiceTests: XCTestCase {
    func testReleasedVssConnectionErrorIsTemporaryWithoutBroadUnknownRetry() {
        XCTAssertTrue(BackupService.isTemporaryBackupFailure(
            VssError.UnknownError(errorDetails: "error sending request for url (http://127.0.0.1:1/putObjects)")
        ))
        XCTAssertTrue(BackupService.isTemporaryBackupFailure(
            VssError.UnknownError(errorDetails: "error sending request for url (https://backup.example/vss/putObjects)")
        ))
        for details in ["invalid ciphertext", "permission denied", "HTTP status client error (401 Unauthorized)",
                        "error sending request for url (not a URL)", "prefix error sending request for url (https://example.com)",
                        "error sending request for url (https://example.com/getObject)",
                        "error sending request for url (file://example.com/putObjects)",
                        "error sending request for url (https:///putObjects)",
                        "error sending request for url (https://example.com/putObjects) suffix"]
        {
            XCTAssertFalse(BackupService.isTemporaryBackupFailure(VssError.UnknownError(errorDetails: details)))
        }
        XCTAssertFalse(BackupService.isTemporaryBackupFailure(URLError(.notConnectedToInternet)))
        XCTAssertFalse(BackupService.isTemporaryBackupFailure(CancellationError()))
    }

    func testReleasedVssConnectionFailureRetriesStoppedUsdtWithBoundedBackoff() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let completed = expectation(description: "Recovery upload acknowledged after connection resumes")
        var attempts = 0
        var delays: [UInt64] = []
        let payload = Data("same-signed-recovery".utf8)
        let service = BackupService(defaults: defaults, backupData: { _ in payload }, uploadBackup: { key, data in
            XCTAssertEqual(key, BackupCategory.usdt.rawValue)
            XCTAssertEqual(data, payload)
            attempts += 1
            if attempts <= 8 {
                throw VssError.UnknownError(errorDetails: "error sending request for url (http://127.0.0.1:1/putObjects)")
            }
        }, waitForBackupDelay: {}, waitForTemporaryFailureDelay: { delays.append($0) })
        await service.stopObservingBackups()
        let subscription = service.backupStatusesPublisher
            .filter { $0[.usdt].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in completed.fulfill() }
        service.markBackupRequired(category: .usdt)
        await fulfillment(of: [completed], timeout: 3)
        subscription.cancel()
        service.setWiping(true)
        await service.stopObservingBackups()
        XCTAssertEqual(attempts, 9)
        XCTAssertEqual(delays, [10, 20, 40, 80, 160, 300, 300, 300].map { UInt64($0) * 1_000_000_000 })
        XCTAssertFalse(service.getBackupStatus(category: .usdt).isRequired)
    }

    func testRepeatedPendingNotificationsDoNotRewriteUnchangedDurableStatus() throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(CountingBackupDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let required = UInt64(Date().timeIntervalSince1970) + 3600
        let pending = BackupItemStatus(synced: 0, required: required, running: false)
        try defaults.set(JSONEncoder().encode([BackupCategory.wallet.rawValue: pending]), forKey: "backupStatuses")
        let service = BackupService(defaults: defaults)
        let writes = defaults.backupStatusWrites
        for _ in 0 ..< 200 {
            service.markBackupRequired(category: .wallet, schedule: false)
        }
        XCTAssertEqual(defaults.backupStatusWrites, writes)
        XCTAssertEqual(service.getBackupStatus(category: .wallet), pending)
        let restarted = BackupService(defaults: defaults)
        XCTAssertEqual(restarted.getBackupStatus(category: .wallet), pending)
    }

    func testPublicAddressMigrationSchedulesWalletBackupOnStartup() async throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(3, forKey: AppDataMigrations.versionKey)
        defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
        defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set("legacy-public-address", forKey: "onchainAddress")
        let synced = BackupItemStatus(synced: 1, required: 1, running: false)
        try defaults.set(JSONEncoder().encode([
            BackupCategory.wallet.rawValue: synced,
            BackupCategory.metadata.rawValue: synced,
        ]), forKey: "backupStatuses")

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        let reservations = PrivatePaykitAddressReservationStore(defaults: defaults)
        var uploadedAddresses: [String]?
        let service = BackupService(defaults: defaults, backupData: { category in
            guard category == .wallet else { return Data() }
            let addresses = await reservations.legacyPublicAddressesSnapshot()
            return try JSONEncoder().encode(WalletBackupV1(
                version: 1, createdAt: 1, transfers: [],
                privatePaykitHighestReservedReceiveIndexByAddressType: nil,
                paykitSdkBackupState: nil, watchOnlyAccounts: nil, watchOnlyAccountAllocationState: nil,
                publicPaykitLegacyAddresses: addresses
            ))
        }, uploadBackup: { key, data in
            guard key == BackupCategory.wallet.rawValue else { return }
            uploadedAddresses = try JSONDecoder().decode(WalletBackupV1.self, from: data).publicPaykitLegacyAddresses
        }, waitForBackupDelay: {})
        let status = service.getBackupStatus(category: .wallet)
        XCTAssertEqual(status.synced, synced.synced)
        XCTAssertTrue(status.isRequired)
        XCTAssertEqual(service.getBackupStatus(category: .metadata), synced)
        guard status.isRequired else { return }
        let completed = expectation(description: "Migrated public address backed up after observation starts")
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        service.startObservingBackups()
        await fulfillment(of: [completed], timeout: 5)
        service.setWiping(true)
        await service.stopObservingBackups()

        XCTAssertEqual(uploadedAddresses, ["legacy-public-address"])
        XCTAssertFalse(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
        XCTAssertNil(defaults.string(forKey: "onchainAddress"))
    }

    func testChangesDuringCaptureAndUploadRemainRequired() async throws {
        for changeDuringCapture in [true, false] {
            let suite = "BackupServiceTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var service: BackupService!
            var shouldChange = true
            service = BackupService(
                defaults: defaults,
                backupData: { _ in
                    if changeDuringCapture, shouldChange {
                        service.markBackupRequired(category: .wallet)
                    }
                    return Data("snapshot".utf8)
                },
                uploadBackup: { _, _ in
                    if !changeDuringCapture, shouldChange {
                        service.markBackupRequired(category: .wallet)
                    }
                }
            )

            await service.triggerBackup(category: .wallet)
            XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
            shouldChange = false
            await service.triggerBackup(category: .wallet)
            XCTAssertFalse(service.getBackupStatus(category: .wallet).isRequired)
            service.setWiping(true)
            await service.stopObservingBackups()
        }
    }

    func testWalletCaptureDiscardsMixedStateAndRecapturesLatestValues() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = WalletBackupChangeTracker()
        var state = 0
        var attempts = 0
        let snapshot = try await tracker.capture {
            attempts += 1
            let earlyRead = state
            if attempts == 1 {
                state = 1
                try Bitkit.WatchOnlyAccountStore.save([], defaults: defaults)
            }
            await Task.yield()
            return [earlyRead, state]
        }
        XCTAssertEqual(snapshot, [1, 1])
        XCTAssertEqual(attempts, 2)
    }

    func testScheduledBackupUploadsChangesFromEveryCategory() async throws {
        for category in BackupCategory.allCases where category != .lightningConnections {
            let suite = "BackupServiceTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let completed = expectation(description: "Latest \(category.rawValue) state backed up")
            var state = Data("initial".utf8)
            var uploads: [Data] = []
            var service: BackupService!
            service = BackupService(defaults: defaults, backupData: { _ in state }, uploadBackup: { key, data in
                XCTAssertEqual(key, category.rawValue)
                uploads.append(data)
                if uploads.count == 1 {
                    state = Data("updated".utf8)
                    service.markBackupRequired(category: category, schedule: false)
                }
            }, waitForBackupDelay: { await Task.yield() })
            let subscription = service.backupStatusesPublisher
                .filter { $0[category].map { !$0.isRequired && !$0.running } == true }
                .first()
                .sink { _ in completed.fulfill() }
            defer { subscription.cancel() }

            service.markBackupRequired(category: category)
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(uploads, [Data("initial".utf8), Data("updated".utf8)], category.rawValue)
            XCTAssertFalse(service.getBackupStatus(category: category).isRequired, category.rawValue)
            service.setWiping(true)
            await service.stopObservingBackups()
        }
    }

    func testAutomaticBackupRetriesContentionAndChangesDuringUpload() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let changes = PassthroughSubject<Void, Never>()
        let tracker = WalletBackupChangeTracker(changes: changes.eraseToAnyPublisher())
        let completed = expectation(description: "All wallet changes backed up")
        var captures = 0
        var uploads: [Data] = []
        var service: BackupService!
        service = BackupService(defaults: defaults, backupData: { _ in
            try await tracker.capture {
                captures += 1
                if captures <= 3 {
                    changes.send()
                }
                return Data("snapshot-\(captures)".utf8)
            }
        }, uploadBackup: { _, data in
            uploads.append(data)
            if uploads.count == 1 {
                service.markBackupRequired(category: .wallet)
            }
        })
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet].map { !$0.isRequired && !$0.running } == true }
            .first()
            .sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        await service.triggerBackup(category: .wallet)
        XCTAssertEqual(captures, 3)
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        await fulfillment(of: [completed], timeout: 15)
        XCTAssertEqual(uploads, [Data("snapshot-4".utf8), Data("snapshot-5".utf8)])
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testWalletCaptureBoundsContentionAndDoesNotRetryOtherFailures() async {
        let changes = PassthroughSubject<Void, Never>()
        let tracker = WalletBackupChangeTracker(changes: changes.eraseToAnyPublisher())
        var attempts = 0
        do {
            try await tracker.capture {
                attempts += 1
                changes.send()
            }
            XCTFail("Expected unstable snapshot to be rejected")
        } catch WalletBackupSnapshotError.changed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(attempts, 3)

        for identityChanged in [true, false] {
            attempts = 0
            do {
                try await tracker.capture {
                    attempts += 1
                    changes.send()
                    if identityChanged {
                        throw PubkyServiceError.identityChanged
                    }
                    throw OnchainSendAttemptError.unresolved
                }
                XCTFail("Expected capture failure")
            } catch PubkyServiceError.identityChanged {
                XCTAssertTrue(identityChanged)
            } catch OnchainSendAttemptError.unresolved {
                XCTAssertFalse(identityChanged)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testStopDrainsCancelledWorkBeforeManualBackupAndRestart() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Scheduled delay started")
        let cancelled = expectation(description: "Scheduled delay cancelled")
        let uploadedEarly = expectation(description: "Manual upload must wait for cleanup")
        uploadedEarly.isInverted = true
        let gate = BackupDelayGate()
        let recorder = BackupRecorder()
        let service = BackupService(defaults: defaults, backupData: { _ in Data("complete".utf8) }, uploadBackup: { key, data in
            await recorder.recordUpload(key: key, data: data)
            if await gate.isHeld {
                uploadedEarly.fulfill()
            }
        }, waitForBackupDelay: {
            try await withTaskCancellationHandler {
                await gate.wait(started: started)
                try Task.checkCancellation()
            } onCancel: { cancelled.fulfill() }
        })
        service.markBackupRequired(category: .wallet)
        await fulfillment(of: [started], timeout: 2)
        let stop = Task {
            await service.stopObservingBackups()
            await gate.recordStop()
        }
        await fulfillment(of: [cancelled], timeout: 2)
        let deferred = expectation(description: "New USDT request survives the drain")
        let deferredSubscription = service.backupStatusesPublisher
            .filter { $0[.usdt].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in deferred.fulfill() }
        service.markBackupRequired(category: .usdt)
        let manual = Task { await service.triggerBackup(category: .activity) }
        await fulfillment(of: [uploadedEarly], timeout: 0.1)
        let stoppedBeforeDrain = await gate.didStop
        XCTAssertFalse(stoppedBeforeDrain)
        await gate.release()
        await stop.value
        let outcome = await manual.value
        await fulfillment(of: [deferred], timeout: 2)
        deferredSubscription.cancel()
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .wallet).running)
        let uploads = await recorder.uploads
        XCTAssertEqual(Set(uploads.map(\.key)), [BackupCategory.activity.rawValue, BackupCategory.usdt.rawValue])
        XCTAssertEqual(uploads.count, 2)
        await service.stopObservingBackups()

        let restarted = BackupService(defaults: defaults, backupData: { _ in Data("latest".utf8) },
                                      uploadBackup: { _, _ in }, waitForBackupDelay: {})
        let completed = expectation(description: "Restart uploads retained work")
        let subscription = restarted.backupStatusesPublisher
            .filter { $0[.wallet].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in completed.fulfill() }
        restarted.startObservingBackups()
        await fulfillment(of: [completed], timeout: 2)
        subscription.cancel()
        await restarted.stopObservingBackups()
        XCTAssertFalse(restarted.getBackupStatus(category: .wallet).isRequired)
    }

    func testRestartRecordsWalletChangesWhilePreviousCleanupDrains() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Old scheduled work started")
        let cancelled = expectation(description: "Old work entered cancellation cleanup")
        let completed = expectation(description: "Restart uploads the change made during cleanup")
        let early = expectation(description: "New upload must wait for old cleanup")
        early.isInverted = true
        let gate = BackupDelayGate()
        let recorder = BackupRecorder()
        var state = Data("initial".utf8)
        var delays = 0
        let service = BackupService(defaults: defaults, backupData: { _ in state }, uploadBackup: { key, data in
            await recorder.recordUpload(key: key, data: data)
            if data == Data("updated".utf8), await gate.isHeld {
                early.fulfill()
            }
        }, waitForBackupDelay: {
            delays += 1
            guard delays == 1 else { return }
            try await withTaskCancellationHandler {
                await gate.wait(started: started)
                try Task.checkCancellation()
            } onCancel: { cancelled.fulfill() }
        })
        await service.triggerBackup(category: .wallet)
        service.markBackupRequired(category: .settings)
        await fulfillment(of: [started], timeout: 2)
        let stop = Task { await service.stopObservingBackups() }
        await fulfillment(of: [cancelled], timeout: 2)

        service.startObservingBackups()
        state = Data("updated".utf8)
        try Bitkit.WatchOnlyAccountStore.save([], defaults: defaults)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        let beforeDrain = await recorder.uploads
        XCTAssertEqual(beforeDrain.map(\.data), [Data("initial".utf8)])
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in completed.fulfill() }
        await fulfillment(of: [early], timeout: 0.1)
        await gate.release()
        await stop.value
        await fulfillment(of: [completed], timeout: 2)
        subscription.cancel()
        await service.stopObservingBackups()
        let uploads = await recorder.uploads.filter { $0.key == BackupCategory.wallet.rawValue }
        XCTAssertEqual(uploads.map(\.data), [Data("initial".utf8), Data("updated".utf8)])
    }

    func testStopRetainsEditsUntilAcknowledgedUploadDrains() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsDefaults = UserDefaults.standard
        let original = settingsDefaults.object(forKey: "swipeBalanceToHide")
        defer {
            if let original {
                settingsDefaults.set(original, forKey: "swipeBalanceToHide")
            } else {
                settingsDefaults.removeObject(forKey: "swipeBalanceToHide")
            }
        }
        let entered = expectation(description: "Captured settings upload entered")
        let cancelled = expectation(description: "Stop cancelled the held upload")
        let unexpectedUpload = expectation(description: "Stopped observers cannot upload new data")
        unexpectedUpload.isInverted = true
        let gate = BackupDelayGate()
        let recorder = BackupRecorder()
        var data = Data("initial".utf8)
        var holdUpload = false
        var mayUploadLatest = false
        let service = BackupService(defaults: defaults, backupData: { _ in data }, uploadBackup: { key, bytes in
            await recorder.recordUpload(key: key, data: bytes)
            if bytes == Data("latest".utf8), !mayUploadLatest {
                unexpectedUpload.fulfill()
            }
            if holdUpload, key == BackupCategory.settings.rawValue {
                holdUpload = false
                await withTaskCancellationHandler {
                    await gate.wait(started: entered)
                } onCancel: { cancelled.fulfill() }
            }
        }, waitForBackupDelay: {})
        await service.triggerBackup(category: .settings)
        await service.triggerBackup(category: .wallet)
        service.startObservingBackups()
        holdUpload = true
        data = Data("captured".utf8)
        settingsDefaults.set(!settingsDefaults.bool(forKey: "swipeBalanceToHide"), forKey: "swipeBalanceToHide")
        await fulfillment(of: [entered], timeout: 2)
        let stop = Task { await service.stopObservingBackups() }
        await fulfillment(of: [cancelled], timeout: 2)

        data = Data("latest".utf8)
        settingsDefaults.set(!settingsDefaults.bool(forKey: "swipeBalanceToHide"), forKey: "swipeBalanceToHide")
        try Bitkit.WatchOnlyAccountStore.save([], defaults: defaults)
        XCTAssertTrue(service.getBackupStatus(category: .settings).isRequired)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        await gate.release()
        await stop.value
        for category in [BackupCategory.settings, .wallet] {
            XCTAssertTrue(service.getBackupStatus(category: category).isRequired)
            XCTAssertFalse(service.getBackupStatus(category: category).running)
        }
        await fulfillment(of: [unexpectedUpload], timeout: 0.1)
        let stoppedUploads = await recorder.uploads
        XCTAssertEqual(stoppedUploads.map(\.data), [Data("initial".utf8), Data("initial".utf8), Data("captured".utf8)])

        mayUploadLatest = true
        let completed = expectation(description: "Restart uploads both latest sources")
        let subscription = service.backupStatusesPublisher
            .filter { statuses in
                [BackupCategory.settings, .wallet].allSatisfy { category in
                    statuses[category].map { !$0.isRequired && !$0.running } == true
                }
            }.first().sink { _ in completed.fulfill() }
        service.startObservingBackups()
        await fulfillment(of: [completed], timeout: 2)
        subscription.cancel()
        await service.stopObservingBackups()
        let latest = await recorder.uploads.filter { $0.data == Data("latest".utf8) }
        XCTAssertEqual(Set(latest.map(\.key)), [BackupCategory.settings.rawValue, BackupCategory.wallet.rawValue])
        XCTAssertEqual(latest.count, 2)
    }

    func testCancelledUploadRetainsNewerSettingsAfterRestart() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entered = expectation(description: "Settings upload entered")
        let gate = BackupDelayGate()
        let service = BackupService(defaults: defaults, backupData: { _ in Data("old".utf8) }, uploadBackup: { _, _ in
            await gate.wait(started: entered)
            try Task.checkCancellation()
        })
        let upload = Task { await service.triggerBackup(category: .settings) }
        await fulfillment(of: [entered], timeout: 2)
        upload.cancel()
        service.markBackupRequired(category: .settings, schedule: false)
        await gate.release()
        let outcome = await upload.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(service.getBackupStatus(category: .settings).isRequired)
        await service.stopObservingBackups()

        let uploaded = expectation(description: "Restart uploads latest settings")
        let restarted = BackupService(defaults: defaults, backupData: { _ in Data("latest".utf8) }, uploadBackup: { key, data in
            XCTAssertEqual(key, BackupCategory.settings.rawValue)
            XCTAssertEqual(data, Data("latest".utf8))
            uploaded.fulfill()
        }, waitForBackupDelay: {})
        restarted.startObservingBackups()
        await fulfillment(of: [uploaded], timeout: 2)
        await restarted.stopObservingBackups()
    }

    func testImmediateStopRetainsReceivedSettingsChange() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsDefaults = UserDefaults.standard
        let original = settingsDefaults.object(forKey: "swipeBalanceToHide")
        defer {
            if let original {
                settingsDefaults.set(original, forKey: "swipeBalanceToHide")
            } else {
                settingsDefaults.removeObject(forKey: "swipeBalanceToHide")
            }
        }
        let service = BackupService(defaults: defaults, backupData: { _ in Data() }, uploadBackup: { _, _ in
            XCTFail("Immediate stop must prevent upload")
        })
        service.startObservingBackups()
        let received = expectation(description: "Settings notification received")
        let subscription = SettingsViewModel.shared.settingsPublisher.first().sink { _ in received.fulfill() }
        settingsDefaults.set(!settingsDefaults.bool(forKey: "swipeBalanceToHide"), forKey: "swipeBalanceToHide")
        await fulfillment(of: [received], timeout: 2)
        subscription.cancel()
        await service.stopObservingBackups()
        XCTAssertTrue(service.getBackupStatus(category: .settings).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .settings).running)
    }

    func testStopWaitsForFinalScheduledStatusWrite() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let delayStarted = expectation(description: "Scheduled backup entered delay")
        let cleanupStarted = expectation(description: "Final status write entered")
        let stoppedEarly = expectation(description: "Stop must wait for final status write")
        stoppedEarly.isInverted = true
        let delayGate = BackupDelayGate()
        let cleanupGate = DispatchSemaphore(value: 0)
        let stopGate = BackupDelayGate()
        let service = BackupService(defaults: defaults, backupData: { _ in Data() },
                                    uploadBackup: { _, _ in XCTFail("Wiping must prevent upload") },
                                    waitForBackupDelay: { await delayGate.wait(started: delayStarted) })
        service.markBackupRequired(category: .wallet)
        await fulfillment(of: [delayStarted], timeout: 2)
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet]?.running == false }
            .first().sink { _ in
                cleanupStarted.fulfill()
                cleanupGate.wait()
            }
        service.setWiping(true)
        await delayGate.release()
        await fulfillment(of: [cleanupStarted], timeout: 2)
        let stop = Task {
            await service.stopObservingBackups()
            if await stopGate.isHeld {
                stoppedEarly.fulfill()
            }
        }
        await fulfillment(of: [stoppedEarly], timeout: 0.1)
        await stopGate.release()
        cleanupGate.signal()
        await stop.value
        subscription.cancel()
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .wallet).running)
    }

    func testImmediateStartStopDoesNotObserveLaterWalletChanges() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = BackupService(defaults: defaults, backupData: { _ in Data("complete".utf8) },
                                    uploadBackup: { _, _ in }, waitForBackupDelay: {})
        for _ in 0 ..< 25 {
            service.startObservingBackups()
            await service.stopObservingBackups()
            let stoppedStatus = service.getBackupStatus(category: .wallet)
            try Bitkit.WatchOnlyAccountStore.save([], defaults: defaults)
            XCTAssertEqual(service.getBackupStatus(category: .wallet), stoppedStatus)
        }
    }

    func testExplicitUsdtBackupRetriesWhileObserversRemainStopped() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let completed = expectation(description: "USDT retry acknowledged without node observation")
        var captures = 0
        let service = BackupService(defaults: defaults, backupData: { _ in
            captures += 1
            if captures == 1 {
                throw PaykitError.SharedStateBusy(code: "shared_state_busy", context: "temporarily unavailable")
            }
            return Data("signed-recovery".utf8)
        }, uploadBackup: { _, _ in }, waitForBackupDelay: {}, waitForTemporaryFailureDelay: { _ in })
        await service.stopObservingBackups()
        let subscription = service.backupStatusesPublisher
            .filter { $0[.usdt].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in completed.fulfill() }
        service.markBackupRequired(category: .usdt)
        await fulfillment(of: [completed], timeout: 2)
        subscription.cancel()
        await service.stopObservingBackups()
        XCTAssertEqual(captures, 2)
        XCTAssertFalse(service.getBackupStatus(category: .usdt).isRequired)
    }

    func testTemporaryFailureRemainsPendingAcrossServiceRestart() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for category in [BackupCategory.wallet, .usdt] {
            let unavailable = BackupService(defaults: defaults, backupData: { _ in
                throw PaykitError.SharedStateBusy(code: "shared_state_busy", context: "pending reconciliation")
            }, waitForBackupDelay: { try await Task.sleep(nanoseconds: 60_000_000_000) })
            await unavailable.triggerBackup(category: category)
            unavailable.setWiping(true)
            await unavailable.stopObservingBackups()
            let restarted = BackupService(defaults: defaults, backupData: { _ in Data("complete".utf8) },
                                          uploadBackup: { _, _ in }, waitForBackupDelay: {})
            XCTAssertTrue(restarted.getBackupStatus(category: category).isRequired)
            let completed = expectation(description: "Restart resumed pending backup")
            let subscription = restarted.backupStatusesPublisher
                .filter { $0[category].map { !$0.isRequired && !$0.running } == true }
                .first().sink { _ in completed.fulfill() }
            restarted.startObservingBackups()
            await fulfillment(of: [completed], timeout: 5)
            subscription.cancel()
            XCTAssertFalse(restarted.getBackupStatus(category: category).isRequired)
            restarted.setWiping(true)
            await restarted.stopObservingBackups()
        }
    }

    func testTemporaryPubkyFailureKeepsWalletWorkAndRetriesWithBoundedBackoff() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let completed = expectation(description: "Pending Paykit snapshot acknowledged")
        var captures = 0
        var delays: [UInt64] = []
        let service = BackupService(defaults: defaults, backupData: { _ in
            captures += 1
            if captures <= 8 {
                throw PaykitError.ConcurrentUpdate(code: "concurrent_update", context: "lock held")
            }
            return Data("complete-wallet".utf8)
        }, uploadBackup: { _, data in
            XCTAssertEqual(data, Data("complete-wallet".utf8))
        }, waitForBackupDelay: {}, waitForTemporaryFailureDelay: { delays.append($0) })
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in completed.fulfill() }
        defer { subscription.cancel() }
        service.markBackupRequired(category: .wallet)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(captures, 9)
        XCTAssertEqual(delays, [10, 20, 40, 80, 160, 300, 300, 300].map { UInt64($0) * 1_000_000_000 })
        XCTAssertFalse(service.getBackupStatus(category: .wallet).isRequired)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testAutomaticBackupDoesNotRepeatUnrelatedFailures() async throws {
        let firstAttempts = expectation(description: "Scheduled backups attempted")
        firstAttempts.expectedFulfillmentCount = 6
        let repeatedAttempt = expectation(description: "Unrelated failure retried")
        repeatedAttempt.isInverted = true
        var services: [(BackupService, BackupCategory)] = []
        var suites: [(UserDefaults, String)] = []
        defer { suites.forEach { $0.0.removePersistentDomain(forName: $0.1) } }
        for category in [BackupCategory.wallet, .settings] {
            for failure in 0 ..< 3 {
                let suite = "BackupServiceTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                suites.append((defaults, suite))
                var attempts = 0
                let service = BackupService(defaults: defaults, backupData: { _ in
                    attempts += 1
                    if attempts == 1 {
                        firstAttempts.fulfill()
                    } else {
                        repeatedAttempt.fulfill()
                    }
                    if failure == 0 {
                        throw PubkyServiceError.identityChanged
                    }
                    if failure == 1 {
                        throw OnchainSendAttemptError.unresolved
                    }
                    return Data("snapshot".utf8)
                }, uploadBackup: { _, _ in throw URLError(.notConnectedToInternet) })
                services.append((service, category))
                service.markBackupRequired(category: category)
            }
        }

        await fulfillment(of: [firstAttempts], timeout: 8)
        await fulfillment(of: [repeatedAttempt], timeout: 6)
        for (service, category) in services {
            XCTAssertTrue(service.getBackupStatus(category: category).isRequired)
            XCTAssertFalse(service.getBackupStatus(category: category).running)
            service.setWiping(true)
            await service.stopObservingBackups()
        }
    }

    func testScheduledBackupRetainsFollowupWhileManualUploadIsBusy() async throws {
        for category in [BackupCategory.wallet, .settings] {
            let suite = "BackupServiceTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let manualUploadStarted = expectation(description: "Manual upload held")
            let firstDelayStarted = expectation(description: "Scheduled backup held")
            let secondDelayStarted = expectation(description: "Busy scheduled backup retained")
            let followupUploaded = expectation(description: "Newer state uploaded")
            let (manualUpload, releaseManualUpload) = AsyncStream<Void>.makeStream()
            let (firstDelay, releaseFirstDelay) = AsyncStream<Void>.makeStream()
            let (secondDelay, releaseSecondDelay) = AsyncStream<Void>.makeStream()
            defer {
                releaseManualUpload.finish()
                releaseFirstDelay.finish()
                releaseSecondDelay.finish()
            }
            var uploads = 0
            var delays = 0
            let service = BackupService(defaults: defaults, backupData: { _ in Data("snapshot".utf8) }, uploadBackup: { _, _ in
                uploads += 1
                if uploads == 1 {
                    manualUploadStarted.fulfill()
                    for await _ in manualUpload {}
                } else {
                    followupUploaded.fulfill()
                }
            }, waitForBackupDelay: {
                delays += 1
                if delays == 1 {
                    firstDelayStarted.fulfill()
                    for await _ in firstDelay {}
                } else {
                    secondDelayStarted.fulfill()
                    for await _ in secondDelay {}
                }
            })
            let manual = Task { await service.triggerBackup(category: category) }
            await fulfillment(of: [manualUploadStarted], timeout: 2)
            service.markBackupRequired(category: category)
            await fulfillment(of: [firstDelayStarted], timeout: 2)
            releaseFirstDelay.finish()
            await fulfillment(of: [secondDelayStarted], timeout: 2)
            releaseManualUpload.finish()
            _ = await manual.value
            XCTAssertTrue(service.getBackupStatus(category: category).isRequired)
            releaseSecondDelay.finish()
            await fulfillment(of: [followupUploaded], timeout: 2)
            XCTAssertEqual(uploads, 2)
            service.setWiping(true)
            await service.stopObservingBackups()
        }
    }

    func testCancellationWinsOverFinalSnapshotContention() async {
        let tracker = WalletBackupChangeTracker(changes: Empty<Void, Never>().eraseToAnyPublisher())
        let capture = Task { () in
            var attempts = 0
            try await tracker.capture {
                attempts += 1
                if attempts == 3 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                throw WalletBackupSnapshotError.changed
            }
        }
        do {
            try await capture.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelledWalletCaptureDoesNotUploadOrRetry() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Wallet capture started")
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let service = BackupService(defaults: defaults, backupData: { _ in
            started.fulfill()
            for await _ in gate {}
            return Data("cancelled".utf8)
        }, uploadBackup: { _, _ in XCTFail("Cancelled capture must not upload") })
        let backup = Task { await service.triggerBackup(category: .wallet) }
        await fulfillment(of: [started], timeout: 2)
        backup.cancel()
        _ = await backup.value
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .wallet).running)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testCancelledDeferredWalletBackupRemainsRequiredAndRetryCompletes() async throws {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backupStarted = expectation(description: "Wallet backup waiting for payment")
        let cancelledBackupFinished = expectation(description: "Cancelled wallet backup finished")
        let recorder = BackupRecorder()
        let sdk = WalletBackupSdk(noPointer: .init())
        sdk.onExport = { await recorder.recordExport() }
        let paykit = PaykitSdkService(sdkFactory: { sdk })
        let service = BackupService(
            defaults: defaults,
            backupData: { category in
                XCTAssertEqual(category, .wallet)
                return try await Data(paykit.exportBackupState().utf8)
            },
            uploadBackup: { key, data in await recorder.recordUpload(key: key, data: data) }
        )
        let statusSubscription = service.backupStatusesPublisher
            .filter { $0[.wallet]?.running == true }
            .first()
            .sink { _ in backupStarted.fulfill() }
        defer { statusSubscription.cancel() }
        let payment = PaykitPaymentActivity.shared.begin()
        defer { PaykitPaymentActivity.shared.end(payment) }
        let backup = Task {
            await service.triggerBackup(category: .wallet)
            cancelledBackupFinished.fulfill()
        }
        await fulfillment(of: [backupStarted], timeout: 2)
        let running = service.getBackupStatus(category: .wallet)
        XCTAssertTrue(running.running)
        XCTAssertTrue(running.isRequired)

        backup.cancel()
        await fulfillment(of: [cancelledBackupFinished], timeout: 2)
        let cancelled = service.getBackupStatus(category: .wallet)
        XCTAssertFalse(cancelled.running)
        XCTAssertTrue(cancelled.isRequired)
        XCTAssertEqual(cancelled.required, running.required)
        XCTAssertEqual(cancelled.synced, running.synced)
        let cancelledExports = await recorder.exports
        let cancelledUploads = await recorder.uploads
        XCTAssertEqual(cancelledExports, 0)
        XCTAssertTrue(cancelledUploads.isEmpty)

        PaykitPaymentActivity.shared.end(payment)
        await backup.value
        await service.triggerBackup(category: .wallet)

        let completed = service.getBackupStatus(category: .wallet)
        XCTAssertFalse(completed.running)
        XCTAssertFalse(completed.isRequired)
        XCTAssertGreaterThan(completed.synced, cancelled.synced)
        let exports = await recorder.exports
        let uploads = await recorder.uploads
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(uploads.map(\.key), [BackupCategory.wallet.rawValue])
        XCTAssertEqual(uploads.map(\.data), [Data("wallet-backup".utf8)])
    }

    func testMetadataReplacementWaitsForDurableWalletExclusions() async throws {
        let firstUpload = expectation(description: "First category upload started")
        let (walletUpload, releaseWalletUpload) = AsyncStream<Void>.makeStream()
        defer { releaseWalletUpload.finish() }
        let remote = LegacyMetadataBackupServer(firstUpload: firstUpload, walletUpload: walletUpload)
        let defaults = try makeLegacyMetadataBackupDefaults()
        let service = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        service.markBackupRequired(category: .wallet, schedule: false)

        let replacement = Task { await service.triggerBackup(category: .metadata) }
        await fulfillment(of: [firstUpload], timeout: 2)
        let heldAttempts = await remote.attemptedKeys
        let heldMetadata = await remote.metadata
        let heldWallet = await remote.wallet
        XCTAssertEqual(heldAttempts, [BackupCategory.wallet.rawValue])
        XCTAssertEqual(heldMetadata, LegacyMetadataBackupServer.legacyMetadata)
        XCTAssertEqual(heldWallet, LegacyMetadataBackupServer.legacyWallet)

        releaseWalletUpload.finish()
        let outcome = await replacement.value
        XCTAssertTrue(outcome == .completed)
        await assertWalletExclusionsPrecedeMetadataReplacement(remote)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testFailedWalletBackupPreservesLegacyRemoteMetadataUntilRetry() async throws {
        let remote = LegacyMetadataBackupServer(failWalletUpload: true)
        let defaults = try makeLegacyMetadataBackupDefaults()
        let service = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        service.markBackupRequired(category: .wallet, schedule: false)

        let outcome = await service.triggerBackup(category: .metadata)
        let failedAttempts = await remote.attemptedKeys
        let metadata = await remote.metadata
        let wallet = await remote.wallet
        XCTAssertTrue(outcome == .failed)
        XCTAssertEqual(failedAttempts, [BackupCategory.wallet.rawValue])
        XCTAssertEqual(metadata, LegacyMetadataBackupServer.legacyMetadata)
        XCTAssertEqual(wallet, LegacyMetadataBackupServer.legacyWallet)
        XCTAssertTrue(service.getBackupStatus(category: .metadata).isRequired)
        service.setWiping(true)
        await service.stopObservingBackups()

        await remote.setWalletUploadFailure(false)
        let restarted = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        XCTAssertTrue(restarted.getBackupStatus(category: .wallet).isRequired)
        XCTAssertTrue(restarted.getBackupStatus(category: .metadata).isRequired)
        let retried = await restarted.triggerBackup(category: .metadata)
        XCTAssertTrue(retried == .completed)
        await assertWalletExclusionsPrecedeMetadataReplacement(remote)
        restarted.setWiping(true)
        await restarted.stopObservingBackups()
    }

    func testTemporaryWalletFailureKeepsMetadataRetryable() async throws {
        let remote = LegacyMetadataBackupServer()
        let defaults = try makeLegacyMetadataBackupDefaults()
        let service = BackupService(
            defaults: defaults,
            backupData: { try await remote.backupData(for: $0) },
            uploadBackup: { key, data in
                if key == BackupCategory.wallet.rawValue {
                    throw PaykitError.ConcurrentUpdate(code: "concurrent_update", context: "held lease")
                }
                try await remote.upload(key: key, data: data)
            },
            waitForBackupDelay: { throw CancellationError() }
        )
        service.markBackupRequired(category: .wallet, schedule: false)

        let outcome = await service.triggerBackup(category: .metadata)
        let metadata = await remote.metadata
        XCTAssertTrue(outcome == .temporarilyUnavailable)
        XCTAssertTrue(outcome.canRetryPendingBackup)
        XCTAssertEqual(metadata, LegacyMetadataBackupServer.legacyMetadata)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertTrue(service.getBackupStatus(category: .metadata).isRequired)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testCancelledWalletBackupPreservesLegacyRemoteMetadataUntilRetry() async throws {
        let firstUpload = expectation(description: "First category upload started")
        let (walletUpload, releaseWalletUpload) = AsyncStream<Void>.makeStream()
        defer { releaseWalletUpload.finish() }
        let remote = LegacyMetadataBackupServer(firstUpload: firstUpload, walletUpload: walletUpload)
        let defaults = try makeLegacyMetadataBackupDefaults()
        let service = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        service.markBackupRequired(category: .wallet, schedule: false)

        let replacement = Task { await service.triggerBackup(category: .metadata) }
        await fulfillment(of: [firstUpload], timeout: 2)
        replacement.cancel()
        let outcome = await replacement.value
        let cancelledAttempts = await remote.attemptedKeys
        let metadata = await remote.metadata
        let wallet = await remote.wallet
        XCTAssertTrue(outcome == .failed)
        XCTAssertEqual(cancelledAttempts, [BackupCategory.wallet.rawValue])
        XCTAssertEqual(metadata, LegacyMetadataBackupServer.legacyMetadata)
        XCTAssertEqual(wallet, LegacyMetadataBackupServer.legacyWallet)
        XCTAssertTrue(service.getBackupStatus(category: .metadata).isRequired)
        service.setWiping(true)
        await service.stopObservingBackups()

        releaseWalletUpload.finish()
        let restarted = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        XCTAssertTrue(restarted.getBackupStatus(category: .wallet).isRequired)
        XCTAssertTrue(restarted.getBackupStatus(category: .metadata).isRequired)
        let retried = await restarted.triggerBackup(category: .metadata)
        XCTAssertTrue(retried == .completed)
        await assertWalletExclusionsPrecedeMetadataReplacement(remote)
        restarted.setWiping(true)
        await restarted.stopObservingBackups()
    }

    func testMetadataRewriteDuringRestorePreservesLegacyRemoteEvidence() async throws {
        let remote = LegacyMetadataBackupServer()
        let defaults = try makeLegacyMetadataBackupDefaults()
        let service = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        service.markBackupRequired(category: .wallet, schedule: false)
        service.setRestoring(true)

        let outcome = await service.triggerBackup(category: .metadata)
        let attempts = await remote.attemptedKeys
        let metadata = await remote.metadata
        XCTAssertFalse(outcome == .completed)
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(metadata, LegacyMetadataBackupServer.legacyMetadata)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertTrue(service.getBackupStatus(category: .metadata).isRequired)

        service.setRestoring(false)
        let retried = await service.triggerBackup(category: .metadata)
        XCTAssertTrue(retried == .completed)
        await assertWalletExclusionsPrecedeMetadataReplacement(remote)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testNewWalletChangeDuringUploadDefersMetadataReplacement() async throws {
        let defaults = try makeLegacyMetadataBackupDefaults()
        let remote = LegacyMetadataBackupServer()
        var shouldChange = true
        var service: BackupService!
        service = BackupService(
            defaults: defaults,
            backupData: { try await remote.backupData(for: $0) },
            uploadBackup: { key, data in
                try await remote.upload(key: key, data: data)
                if key == BackupCategory.wallet.rawValue, shouldChange {
                    shouldChange = false
                    await remote.setWalletSnapshot(LegacyMetadataBackupServer.newerWalletWithExclusions)
                    service.markBackupRequired(category: .wallet, schedule: false)
                }
            },
            waitForBackupDelay: { throw CancellationError() }
        )
        service.markBackupRequired(category: .wallet, schedule: false)

        let outcome = await service.triggerBackup(category: .metadata)
        let firstUploads = await remote.successfulKeys
        let retainedMetadata = await remote.metadata
        XCTAssertFalse(outcome == .completed)
        XCTAssertEqual(firstUploads, [BackupCategory.wallet.rawValue])
        XCTAssertEqual(retainedMetadata, LegacyMetadataBackupServer.legacyMetadata)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertTrue(service.getBackupStatus(category: .metadata).isRequired)

        let retried = await service.triggerBackup(category: .metadata)
        let successfulKeys = await remote.successfulKeys
        let wallet = await remote.wallet
        let metadata = await remote.metadata
        XCTAssertTrue(retried == .completed)
        XCTAssertEqual(successfulKeys, [BackupCategory.wallet.rawValue, BackupCategory.wallet.rawValue, BackupCategory.metadata.rawValue])
        XCTAssertEqual(wallet, LegacyMetadataBackupServer.newerWalletWithExclusions)
        XCTAssertEqual(metadata, LegacyMetadataBackupServer.replacementMetadata)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testRestoreCompletionPreservesImportedWalletBackupRequirement() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
        let defaults = try makeLegacyMetadataBackupDefaults()
        let remote = LegacyMetadataBackupServer()
        let service = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        let payload = try JSONDecoder().decode(MetadataBackupV1.self, from: LegacyMetadataBackupServer.legacyMetadata)
        var recordedBeforeImport = false
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet]?.isRequired == true }
            .first()
            .sink { _ in
                recordedBeforeImport = UserDefaults.standard.stringArray(
                    forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey
                )?.contains(LegacyMetadataBackupServer.legacyAddress) != true
            }
        defer { subscription.cancel() }

        try await service.restoreAppCacheData(payload.cache)
        let required = service.getBackupStatus(category: .wallet)
        XCTAssertTrue(recordedBeforeImport)
        XCTAssertTrue(required.isRequired)
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey),
            [LegacyMetadataBackupServer.legacyAddress]
        )
        service.markRestoreComplete(category: .wallet)
        XCTAssertEqual(service.getBackupStatus(category: .wallet), required)
        service.setRestoring(false)
        service.setWiping(true)
        await service.stopObservingBackups()

        let restarted = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        XCTAssertEqual(restarted.getBackupStatus(category: .wallet), required)
        let outcome = await restarted.triggerBackup(category: .metadata)
        XCTAssertTrue(outcome == .completed)
        await assertWalletExclusionsPrecedeMetadataReplacement(remote)
        restarted.setWiping(true)
        await restarted.stopObservingBackups()
    }

    func testCacheRestoreDrainsAdmittedMetadataBeforeImport() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
        let defaults = try makeLegacyMetadataBackupDefaults()
        let remote = LegacyMetadataBackupServer()
        let uploadStarted = expectation(description: "Metadata upload admitted")
        let importFinished = expectation(description: "Cache imported before admitted metadata finished")
        importFinished.isInverted = true
        let (upload, releaseUpload) = AsyncStream<Void>.makeStream()
        defer { releaseUpload.finish() }
        var metadataFinished = false
        var requirementAfterUpload = false
        let service = BackupService(
            defaults: defaults,
            backupData: { try await remote.backupData(for: $0) },
            uploadBackup: { key, data in
                if key == BackupCategory.metadata.rawValue {
                    uploadStarted.fulfill()
                    for await _ in upload {}
                }
                try await remote.upload(key: key, data: data)
                metadataFinished = true
            },
            waitForBackupDelay: { throw CancellationError() }
        )
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet]?.isRequired == true }
            .first()
            .sink { _ in requirementAfterUpload = metadataFinished }
        defer { subscription.cancel() }
        let pendingMetadata = Task { await service.triggerBackup(category: .metadata) }
        await fulfillment(of: [uploadStarted], timeout: 2)
        let payload = try JSONDecoder().decode(MetadataBackupV1.self, from: LegacyMetadataBackupServer.legacyMetadata)
        let restore = Task {
            try await service.restoreAppCacheData(payload.cache)
            importFinished.fulfill()
        }

        await fulfillment(of: [importFinished], timeout: 0.1)
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey))
        XCTAssertFalse(service.getBackupStatus(category: .wallet).isRequired)
        releaseUpload.finish()
        _ = await pendingMetadata.value
        try await restore.value
        XCTAssertTrue(requirementAfterUpload)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey),
            [LegacyMetadataBackupServer.legacyAddress]
        )
        service.setRestoring(false)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testStopAndCacheRestoreDrainCancelledMetadataUpload() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
        let defaults = try makeLegacyMetadataBackupDefaults()
        let remote = LegacyMetadataBackupServer()
        let payload = try JSONDecoder().decode(MetadataBackupV1.self, from: LegacyMetadataBackupServer.legacyMetadata)
        let uploadStarted = expectation(description: "Metadata upload admitted")
        let uploadCancelled = expectation(description: "Metadata upload cancellation requested")
        let stopFinished = expectation(description: "Backup observation stopped before admitted metadata finished")
        stopFinished.isInverted = true
        let importFinished = expectation(description: "Cache imported before admitted metadata finished")
        importFinished.isInverted = true
        var metadataFinished = false
        var requirementAfterUpload = false
        let service = BackupService(
            defaults: defaults,
            backupData: { try await remote.backupData(for: $0) },
            uploadBackup: { key, data in
                if key == BackupCategory.metadata.rawValue {
                    await withTaskCancellationHandler {
                        await remote.holdMetadataUpload(started: uploadStarted)
                    } onCancel: {
                        uploadCancelled.fulfill()
                    }
                }
                try await remote.upload(key: key, data: data)
                metadataFinished = true
            },
            waitForBackupDelay: { throw CancellationError() }
        )
        let subscription = service.backupStatusesPublisher
            .filter { $0[.wallet]?.isRequired == true }
            .first()
            .sink { _ in requirementAfterUpload = metadataFinished }
        defer { subscription.cancel() }
        let pendingMetadata = Task { await service.triggerBackup(category: .metadata) }
        await fulfillment(of: [uploadStarted], timeout: 2)
        let stop = Task {
            await service.stopObservingBackups()
            stopFinished.fulfill()
        }
        await fulfillment(of: [uploadCancelled], timeout: 2)
        let restore = Task {
            try await service.restoreAppCacheData(payload.cache)
            importFinished.fulfill()
        }

        await fulfillment(of: [stopFinished, importFinished], timeout: 0.1)
        XCTAssertFalse(metadataFinished)
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey))
        XCTAssertFalse(service.getBackupStatus(category: .wallet).isRequired)
        await remote.releaseMetadataUpload()
        _ = await pendingMetadata.value
        await stop.value
        try await restore.value
        XCTAssertTrue(metadataFinished)
        XCTAssertTrue(requirementAfterUpload)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey),
            [LegacyMetadataBackupServer.legacyAddress]
        )
        service.setRestoring(false)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testWalletChangeDuringMetadataCaptureDefersUpload() async throws {
        let defaults = try makeLegacyMetadataBackupDefaults()
        let remote = LegacyMetadataBackupServer()
        var shouldChange = true
        var service: BackupService!
        service = BackupService(
            defaults: defaults,
            backupData: { category in
                let data = try await remote.backupData(for: category)
                if category == .metadata, shouldChange {
                    shouldChange = false
                    service.markBackupRequired(category: .wallet, schedule: false)
                }
                return data
            },
            uploadBackup: { try await remote.upload(key: $0, data: $1) },
            waitForBackupDelay: { throw CancellationError() }
        )
        let deferred = await service.triggerBackup(category: .metadata)
        let attempts = await remote.attemptedKeys
        XCTAssertFalse(deferred == .completed)
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertTrue(service.getBackupStatus(category: .metadata).isRequired)

        let retried = await service.triggerBackup(category: .metadata)
        XCTAssertTrue(retried == .completed)
        await assertWalletExclusionsPrecedeMetadataReplacement(remote)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testMetadataWaitsForExistingWalletCategoryUpload() async throws {
        let firstUpload = expectation(description: "Wallet upload started")
        let metadataFinished = expectation(description: "Metadata finished before the existing wallet upload")
        metadataFinished.isInverted = true
        let (walletUpload, releaseWalletUpload) = AsyncStream<Void>.makeStream()
        defer { releaseWalletUpload.finish() }
        let remote = LegacyMetadataBackupServer(firstUpload: firstUpload, walletUpload: walletUpload)
        let defaults = try makeLegacyMetadataBackupDefaults()
        let service = makeLegacyMetadataBackupService(defaults: defaults, remote: remote)
        service.markBackupRequired(category: .wallet, schedule: false)
        let wallet = Task { await service.triggerBackup(category: .wallet) }
        await fulfillment(of: [firstUpload], timeout: 2)
        let metadata = Task {
            let outcome = await service.triggerBackup(category: .metadata)
            metadataFinished.fulfill()
            return outcome
        }

        await fulfillment(of: [metadataFinished], timeout: 0.1)
        releaseWalletUpload.finish()
        _ = await wallet.value
        let outcome = await metadata.value
        XCTAssertTrue(outcome == .completed)
        await assertWalletExclusionsPrecedeMetadataReplacement(remote)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    func testCancellingMetadataWaitDoesNotCancelExistingWalletUpload() async throws {
        let walletStarted = expectation(description: "Wallet upload started")
        let walletCancelled = expectation(description: "Metadata waiter cancelled another owner's wallet upload")
        walletCancelled.isInverted = true
        let metadataFinished = expectation(description: "Metadata finished before the held wallet upload")
        metadataFinished.isInverted = true
        let (heldUpload, releaseUpload) = AsyncStream<Void>.makeStream()
        defer { releaseUpload.finish() }
        let defaults = try makeIsolatedDefaults()
        var uploadedKeys: [String] = []
        let service = BackupService(defaults: defaults, backupData: { _ in Data() }, uploadBackup: { key, _ in
            if key == BackupCategory.wallet.rawValue {
                await withTaskCancellationHandler {
                    walletStarted.fulfill()
                    for await _ in heldUpload {}
                } onCancel: {
                    walletCancelled.fulfill()
                }
            }
            uploadedKeys.append(key)
        }, waitForBackupDelay: { throw CancellationError() })
        service.markBackupRequired(category: .wallet, schedule: false)
        let wallet = Task { await service.triggerBackup(category: .wallet) }
        await fulfillment(of: [walletStarted], timeout: 2)
        let metadata = Task {
            let outcome = await service.triggerBackup(category: .metadata)
            metadataFinished.fulfill()
            return outcome
        }
        await fulfillment(of: [metadataFinished], timeout: 0.1)
        metadata.cancel()
        await fulfillment(of: [walletCancelled], timeout: 0.1)
        releaseUpload.finish()
        let walletOutcome = await wallet.value
        let metadataOutcome = await metadata.value
        XCTAssertTrue(walletOutcome == .completed)
        XCTAssertFalse(metadataOutcome == .completed)
        XCTAssertEqual(uploadedKeys, [BackupCategory.wallet.rawValue])
        XCTAssertTrue(service.getBackupStatus(category: .metadata).isRequired)
        service.setWiping(true)
        await service.stopObservingBackups()
    }

    private func makeLegacyMetadataBackupDefaults() throws -> UserDefaults {
        let defaults = try makeIsolatedDefaults()
        defaults.set([LegacyMetadataBackupServer.legacyAddress], forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
        let statuses = [BackupCategory.wallet.rawValue: BackupItemStatus(synced: 1, required: 1, running: false)]
        try defaults.set(JSONEncoder().encode(statuses), forKey: "backupStatuses")
        return defaults
    }

    private func makeLegacyMetadataBackupService(defaults: UserDefaults, remote: LegacyMetadataBackupServer) -> BackupService {
        return BackupService(
            defaults: defaults,
            backupData: { try await remote.backupData(for: $0) },
            uploadBackup: { try await remote.upload(key: $0, data: $1) },
            waitForBackupDelay: { throw CancellationError() }
        )
    }

    private func assertWalletExclusionsPrecedeMetadataReplacement(
        _ remote: LegacyMetadataBackupServer, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let successfulKeys = await remote.successfulKeys
        let wallet = await remote.wallet
        let metadata = await remote.metadata
        XCTAssertEqual(successfulKeys, [BackupCategory.wallet.rawValue, BackupCategory.metadata.rawValue], file: file, line: line)
        XCTAssertEqual(wallet, LegacyMetadataBackupServer.walletWithExclusion, file: file, line: line)
        XCTAssertEqual(metadata, LegacyMetadataBackupServer.replacementMetadata, file: file, line: line)
    }
}

private actor LegacyMetadataBackupServer {
    static let legacyAddress = "bcrt1qlegacy-public"
    static let legacyWallet = Data(#"{"version":1,"createdAt":1,"transfers":[]}"#.utf8)
    static let legacyMetadata = Data(
        #"{"version":1,"createdAt":1,"tagMetadata":[],"cache":{"onchainAddress":"bcrt1qlegacy-public"}}"#.utf8
    )
    static let walletWithExclusion = Data(
        #"{"version":1,"createdAt":2,"transfers":[],"publicPaykitLegacyAddresses":["bcrt1qlegacy-public"]}"#.utf8
    )
    static let newerWalletWithExclusions = Data(
        #"{"version":1,"createdAt":3,"transfers":[],"publicPaykitLegacyAddresses":["bcrt1qlegacy-public","bcrt1qanother-public"]}"#.utf8
    )
    static let replacementMetadata = Data(#"{"version":1,"createdAt":2,"tagMetadata":[],"cache":{}}"#.utf8)

    private(set) var wallet = LegacyMetadataBackupServer.legacyWallet
    private(set) var metadata = LegacyMetadataBackupServer.legacyMetadata
    private(set) var attemptedKeys: [String] = []
    private(set) var successfulKeys: [String] = []
    private let firstUpload: XCTestExpectation?
    private let walletUpload: AsyncStream<Void>?
    private var failWalletUpload: Bool
    private var walletSnapshot = LegacyMetadataBackupServer.walletWithExclusion
    private var metadataUploadContinuation: CheckedContinuation<Void, Never>?

    init(firstUpload: XCTestExpectation? = nil, walletUpload: AsyncStream<Void>? = nil, failWalletUpload: Bool = false) {
        self.firstUpload = firstUpload
        self.walletUpload = walletUpload
        self.failWalletUpload = failWalletUpload
    }

    func backupData(for category: BackupCategory) throws -> Data {
        switch category {
        case .wallet: walletSnapshot
        case .metadata: Self.replacementMetadata
        default: throw URLError(.unsupportedURL)
        }
    }

    func setWalletUploadFailure(_ value: Bool) {
        failWalletUpload = value
    }

    func setWalletSnapshot(_ data: Data) {
        walletSnapshot = data
    }

    func holdMetadataUpload(started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            metadataUploadContinuation = continuation
            started.fulfill()
        }
    }

    func releaseMetadataUpload() {
        metadataUploadContinuation?.resume()
        metadataUploadContinuation = nil
    }

    func upload(key: String, data: Data) async throws {
        attemptedKeys.append(key)
        if attemptedKeys.count == 1 {
            firstUpload?.fulfill()
        }
        if key == BackupCategory.wallet.rawValue {
            if let walletUpload {
                for await _ in walletUpload {}
            }
            try Task.checkCancellation()
            if failWalletUpload {
                throw URLError(.notConnectedToInternet)
            }
            wallet = data
        } else if key == BackupCategory.metadata.rawValue {
            metadata = data
        }
        successfulKeys.append(key)
    }
}

private actor BackupRecorder {
    private(set) var exports = 0
    private(set) var uploads: [(key: String, data: Data)] = []

    func recordExport() {
        exports += 1
    }

    func recordUpload(key: String, data: Data) {
        uploads.append((key, data))
    }
}

private final class WalletBackupSdk: PaykitSdk, @unchecked Sendable {
    var onExport: () async -> Void = {}

    override func identityStatus() async throws -> IdentityStatus? {
        IdentityStatus(publicKey: nil, capability: .privateLinkCapable)
    }

    override func exportBackupString() async throws -> String {
        await onExport()
        return "wallet-backup"
    }
}

private final class CountingBackupDefaults: UserDefaults {
    private let writeLock = NSLock()
    private var writes = 0

    var backupStatusWrites: Int {
        writeLock.withLock { writes }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "backupStatuses" {
            writeLock.withLock { writes += 1 }
        }
        super.set(value, forKey: defaultName)
    }
}

private actor BackupDelayGate {
    private(set) var isHeld = true
    private(set) var didStop = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(started: XCTestExpectation) async {
        guard isHeld else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func recordStop() {
        didStop = true
    }

    func release() {
        isHeld = false
        continuation?.resume()
        continuation = nil
    }
}
