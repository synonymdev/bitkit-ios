@testable import Bitkit
import Combine
import Paykit
import XCTest

@MainActor
final class BackupServiceTests: XCTestCase {
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
        let manual = Task { await service.triggerBackup(category: .metadata) }
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
        XCTAssertEqual(Set(uploads.map(\.key)), [BackupCategory.metadata.rawValue, BackupCategory.usdt.rawValue])
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
        let original = SettingsViewModel.shared.swipeBalanceToHide
        defer { SettingsViewModel.shared.swipeBalanceToHide = original }
        let service = BackupService(defaults: defaults, backupData: { _ in Data() }, uploadBackup: { _, _ in
            XCTFail("Immediate stop must prevent upload")
        })
        service.startObservingBackups()
        let received = expectation(description: "Settings notification received")
        let subscription = SettingsViewModel.shared.settingsPublisher.first().sink { _ in received.fulfill() }
        SettingsViewModel.shared.swipeBalanceToHide = !original
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
