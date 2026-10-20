@testable import Bitkit
import Combine
import XCTest

@MainActor
final class BackupForegroundRecoveryTests: XCTestCase {
    func testForegroundRecoversEveryPendingCategoryWithoutStaleAlert() async throws {
        let fixture = try Fixture(categories: BackupCategory.allCases.filter { $0 != .lightningConnections })
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let service = fixture.service(uploadBackup: { key, _ in await uploads.record(key) })
        await service.startObservingBackups()?.value
        let staleAlert = expectation(description: "Recovered backups must not emit a failure alert")
        staleAlert.isInverted = true
        let subscription = service.backupFailurePublisher.sink { _ in staleAlert.fulfill() }
        defer { subscription.cancel() }

        let recoveryTime = UInt64(Date().timeIntervalSince1970)
        await service.setAppActive(true)?.value
        await fulfillment(of: [staleAlert], timeout: 0.2)

        let recorded = await uploads.counts
        for category in fixture.categories {
            let status = service.getBackupStatus(category: category)
            XCTAssertEqual(recorded[category.rawValue], 1, category.rawValue)
            XCTAssertFalse(status.isRequired, category.rawValue)
            XCTAssertFalse(status.running, category.rawValue)
            XCTAssertGreaterThanOrEqual(status.synced, recoveryTime, category.rawValue)
        }
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testFailedRecoveryWaitsForOtherRetriesAndPreservesAgeAndCooldown() async throws {
        let fixture = try Fixture(categories: [.settings, .widgets])
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let failed = expectation(description: "Settings retry failed")
        let started = expectation(description: "Widgets retry started")
        let (uploadGate, releaseUpload) = AsyncStream<Void>.makeStream()
        defer { releaseUpload.finish() }
        let service = fixture.service(uploadBackup: { key, _ in
            await uploads.record(key)
            if key == BackupCategory.settings.rawValue {
                throw URLError(.notConnectedToInternet)
            }
            started.fulfill()
            for await _ in uploadGate {}
        })
        await service.startObservingBackups()?.value
        let statusSubscription = service.backupStatusesPublisher
            .map { $0[.settings]?.running == true }
            .removeDuplicates()
            .drop(while: { !$0 })
            .filter { !$0 }
            .first()
            .sink { _ in failed.fulfill() }
        defer { statusSubscription.cancel() }
        let earlyAlert = expectation(description: "No alert until all foreground retries settle")
        earlyAlert.isInverted = true
        var failureSubscription = service.backupFailurePublisher.sink { _ in earlyAlert.fulfill() }

        let recovery = service.setAppActive(true)
        await fulfillment(of: [failed, started], timeout: 2)
        await fulfillment(of: [earlyAlert], timeout: 0.2)
        failureSubscription.cancel()

        let genuineAlert = expectation(description: "Still-failing overdue backup is reported")
        failureSubscription = service.backupFailurePublisher.sink { _ in genuineAlert.fulfill() }
        releaseUpload.finish()
        await recovery?.value
        await fulfillment(of: [genuineAlert], timeout: 2)
        failureSubscription.cancel()

        XCTAssertEqual(service.getBackupStatus(category: .settings).required, fixture.required)
        XCTAssertTrue(service.getBackupStatus(category: .settings).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .widgets).isRequired)

        let repeatedAlert = expectation(description: "Foreground retry must preserve notification cooldown")
        repeatedAlert.isInverted = true
        failureSubscription = service.backupFailurePublisher.sink { _ in repeatedAlert.fulfill() }
        service.setAppActive(false)
        await service.setAppActive(true)?.value
        await fulfillment(of: [repeatedAlert], timeout: 0.2)
        failureSubscription.cancel()
        let recorded = await uploads.counts
        XCTAssertEqual(recorded[BackupCategory.settings.rawValue], 2)
        XCTAssertEqual(recorded[BackupCategory.widgets.rawValue], 1)
        XCTAssertEqual(service.getBackupStatus(category: .settings).required, fixture.required)
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testForegroundDoesNotDuplicateRunningOrScheduledBackups() async throws {
        let fixture = try Fixture(categories: [.settings, .widgets])
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let uploading = expectation(description: "Manual settings backup started")
        let scheduled = expectation(description: "Widgets backup scheduled")
        let completed = expectation(description: "Scheduled widgets backup completed")
        let (uploadGate, releaseUpload) = AsyncStream<Void>.makeStream()
        let (delayGate, releaseDelay) = AsyncStream<Void>.makeStream()
        defer {
            releaseUpload.finish()
            releaseDelay.finish()
        }
        let service = fixture.service(uploadBackup: { key, _ in
            await uploads.record(key)
            if key == BackupCategory.settings.rawValue {
                uploading.fulfill()
                for await _ in uploadGate {}
            }
        }, waitForBackupDelay: {
            scheduled.fulfill()
            for await _ in delayGate {}
        })
        await service.startObservingBackups()?.value
        let manual = Task { await service.triggerBackup(category: .settings) }
        await fulfillment(of: [uploading], timeout: 2)
        service.markBackupRequired(category: .widgets)
        await fulfillment(of: [scheduled], timeout: 2)

        await service.setAppActive(true)?.value
        let recorded = await uploads.counts
        XCTAssertEqual(recorded, [BackupCategory.settings.rawValue: 1])

        let subscription = service.backupStatusesPublisher
            .filter { $0[.widgets].map { !$0.isRequired && !$0.running } == true }
            .first()
            .sink { _ in completed.fulfill() }
        defer { subscription.cancel() }
        releaseUpload.finish()
        _ = await manual.value
        releaseDelay.finish()
        await fulfillment(of: [completed], timeout: 2)
        let finished = await uploads.counts
        XCTAssertEqual(finished, [BackupCategory.settings.rawValue: 1, BackupCategory.widgets.rawValue: 1])
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testStoppingRecoveryRetainsPendingBackupAndDoesNotUpload() async throws {
        let fixture = try Fixture(categories: [.settings])
        defer { fixture.removeDefaults() }
        let capturing = expectation(description: "Foreground backup capture started")
        let (captureGate, releaseCapture) = AsyncStream<Void>.makeStream()
        defer { releaseCapture.finish() }
        let service = BackupService(defaults: fixture.defaults, backupData: { _ in
            capturing.fulfill()
            for await _ in captureGate {}
            return Data("isolated-snapshot".utf8)
        }, uploadBackup: { _, _ in XCTFail("Stopped recovery must not upload") })
        await service.startObservingBackups()?.value

        let recovery = service.setAppActive(true)
        await fulfillment(of: [capturing], timeout: 2)
        service.setWiping(true)
        await service.stopObservingBackups()
        releaseCapture.finish()
        await recovery?.value

        let status = service.getBackupStatus(category: .settings)
        XCTAssertTrue(status.isRequired)
        XCTAssertEqual(status.required, fixture.required)
        XCTAssertFalse(status.running)
        service.setAppActive(false)
    }

    func testForegroundDoesNotRetryWithoutObservationOrDuringRestoreOrWipe() async throws {
        let fixture = try Fixture(categories: [.settings])
        defer { fixture.removeDefaults() }
        let service = fixture.service(uploadBackup: { _, _ in XCTFail("Recovery must not upload") })
        await service.setAppActive(true)?.value
        service.setAppActive(false)
        await service.startObservingBackups()?.value

        service.setRestoring(true)
        await service.setAppActive(true)?.value
        service.setAppActive(false)
        service.setRestoring(false)
        service.setWiping(true)
        await service.setAppActive(true)?.value

        XCTAssertTrue(service.getBackupStatus(category: .settings).isRequired)
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testHungRetryDoesNotSuppressOtherOverdueFailures() async throws {
        let fixture = try Fixture(categories: [.settings, .metadata])
        defer { fixture.removeDefaults() }
        let hung = expectation(description: "Metadata retry is held")
        let failed = expectation(description: "Settings retry failed")
        let recovered = expectation(description: "Metadata upload eventually succeeds")
        let alert = expectation(description: "Overdue settings failure is reported while metadata is running")
        let (uploadGate, releaseUpload) = AsyncStream<Void>.makeStream()
        let (timeoutGate, expireWindow) = AsyncStream<Void>.makeStream()
        defer {
            releaseUpload.finish()
            expireWindow.finish()
        }
        let service = fixture.service(uploadBackup: { key, _ in
            if key == BackupCategory.settings.rawValue {
                throw URLError(.notConnectedToInternet)
            }
            hung.fulfill()
            for await _ in uploadGate {}
            XCTAssertFalse(Task.isCancelled, "Expiring the recovery window must not cancel an upload")
        }, waitForForegroundRecoveryTimeout: {
            for await _ in timeoutGate {}
        })
        await service.startObservingBackups()?.value
        let failedSubscription = service.backupStatusesPublisher
            .map { $0[.settings]?.running == true }
            .removeDuplicates()
            .drop(while: { !$0 })
            .filter { !$0 }
            .first()
            .sink { _ in failed.fulfill() }
        let recoveredSubscription = service.backupStatusesPublisher
            .filter { $0[.metadata].map { !$0.isRequired && !$0.running } == true }
            .first()
            .sink { _ in recovered.fulfill() }
        let failureSubscription = service.backupFailurePublisher.sink { _ in alert.fulfill() }
        defer {
            failedSubscription.cancel()
            recoveredSubscription.cancel()
            failureSubscription.cancel()
        }

        let recovery = service.setAppActive(true)
        await fulfillment(of: [hung, failed], timeout: 2)
        expireWindow.finish()
        await fulfillment(of: [alert], timeout: 2)

        XCTAssertTrue(service.getBackupStatus(category: .metadata).running)
        XCTAssertTrue(service.getBackupStatus(category: .settings).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .settings).running)
        XCTAssertEqual(service.getBackupStatus(category: .settings).required, fixture.required)
        releaseUpload.finish()
        await fulfillment(of: [recovered], timeout: 2)
        await recovery?.value
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testLateRetryCompletionDoesNotEndNewRecoveryWindow() async throws {
        let fixture = try Fixture(categories: [.settings, .metadata])
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let deadlines = UploadRecorder()
        let oldUploadStarted = expectation(description: "First window has a held metadata upload")
        let oldRetryFailed = expectation(description: "First settings retry failed")
        let oldDeadlineStarted = expectation(description: "First window has its own deadline")
        let oldWindowEnded = expectation(description: "First window ends while its upload is still held")
        let newUploadStarted = expectation(description: "Second window has a held settings upload")
        let newDeadlineStarted = expectation(description: "Second window has its own deadline")
        let oldUploadFinished = expectation(description: "First window's upload finishes late")
        let newWindowStillWaiting = expectation(description: "Second window stays open until its own completion or deadline")
        newWindowStillWaiting.isInverted = true
        let (oldUpload, releaseOldUpload) = AsyncStream<Void>.makeStream()
        let (newUpload, releaseNewUpload) = AsyncStream<Void>.makeStream()
        let (oldTimeout, expireOldWindow) = AsyncStream<Void>.makeStream()
        let (newTimeout, expireNewWindow) = AsyncStream<Void>.makeStream()
        defer {
            releaseOldUpload.finish()
            releaseNewUpload.finish()
            expireOldWindow.finish()
            expireNewWindow.finish()
        }
        let service = fixture.service(uploadBackup: { key, _ in
            await uploads.record(key)
            if key == BackupCategory.metadata.rawValue {
                oldUploadStarted.fulfill()
                for await _ in oldUpload {}
                return
            }
            let counts = await uploads.counts
            if counts[key] == 1 {
                throw URLError(.notConnectedToInternet)
            }
            newUploadStarted.fulfill()
            for await _ in newUpload {}
            throw URLError(.notConnectedToInternet)
        }, waitForForegroundRecoveryTimeout: {
            await deadlines.record("window")
            let counts = await deadlines.counts
            if counts["window"] == 1 {
                oldDeadlineStarted.fulfill()
                for await _ in oldTimeout {}
            } else {
                newDeadlineStarted.fulfill()
                for await _ in newTimeout {}
            }
        })
        await service.startObservingBackups()?.value
        let subscription = service.backupStatusesPublisher
            .filter { $0[.metadata].map { !$0.isRequired && !$0.running } == true }
            .first()
            .sink { _ in oldUploadFinished.fulfill() }
        let failureSubscription = service.backupStatusesPublisher
            .map { $0[.settings]?.running == true }
            .removeDuplicates()
            .drop(while: { !$0 })
            .filter { !$0 }
            .first()
            .sink { _ in oldRetryFailed.fulfill() }
        defer {
            subscription.cancel()
            failureSubscription.cancel()
        }

        let oldRecovery = service.setAppActive(true)
        let oldWindowCompletion = Task {
            await oldRecovery?.value
            oldWindowEnded.fulfill()
        }
        await fulfillment(of: [oldUploadStarted, oldRetryFailed, oldDeadlineStarted], timeout: 2)
        expireOldWindow.finish()
        await fulfillment(of: [oldWindowEnded], timeout: 2)
        service.setAppActive(false)
        let newRecovery = service.setAppActive(true)
        let newWindowCompletion = Task {
            await newRecovery?.value
            if !Task.isCancelled {
                newWindowStillWaiting.fulfill()
            }
        }
        await fulfillment(of: [newUploadStarted, newDeadlineStarted], timeout: 2)

        releaseOldUpload.finish()
        await fulfillment(of: [oldUploadFinished], timeout: 2)
        await fulfillment(of: [newWindowStillWaiting], timeout: 0.2)
        XCTAssertNil(service.setAppActive(true), "A late retry must not release the newer window's gate")
        let counts = await uploads.counts
        XCTAssertEqual(counts[BackupCategory.metadata.rawValue], 1)
        XCTAssertEqual(counts[BackupCategory.settings.rawValue], 2)

        newWindowCompletion.cancel()
        service.setAppActive(false)
        releaseNewUpload.finish()
        await newWindowCompletion.value
        await oldWindowCompletion.value
        await service.stopObservingBackups()
    }
}

private struct Fixture {
    let suite = "BackupForegroundRecoveryTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let categories: [BackupCategory]
    let required = UInt64(Date().timeIntervalSince1970) - 31 * 60

    init(categories: [BackupCategory]) throws {
        self.categories = categories
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let statuses = Dictionary(uniqueKeysWithValues: categories.map {
            ($0.rawValue, BackupItemStatus(synced: 0, required: required, running: false))
        })
        try defaults.set(JSONEncoder().encode(statuses), forKey: "backupStatuses")
    }

    func service(
        uploadBackup: @escaping (String, Data) async throws -> Void,
        waitForBackupDelay: @escaping () async throws -> Void = { throw CancellationError() },
        waitForForegroundRecoveryTimeout: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(60)) }
    ) -> BackupService {
        BackupService(
            defaults: defaults,
            backupData: { _ in Data("isolated-snapshot".utf8) },
            uploadBackup: uploadBackup,
            waitForBackupDelay: waitForBackupDelay,
            waitForForegroundRecoveryTimeout: waitForForegroundRecoveryTimeout
        )
    }

    func removeDefaults() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor UploadRecorder {
    private(set) var counts: [String: Int] = [:]

    func record(_ key: String) {
        counts[key, default: 0] += 1
    }
}
