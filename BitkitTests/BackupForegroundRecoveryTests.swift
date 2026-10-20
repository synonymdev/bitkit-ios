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
        waitForBackupDelay: @escaping () async throws -> Void = { throw CancellationError() }
    ) -> BackupService {
        BackupService(
            defaults: defaults,
            backupData: { _ in Data("isolated-snapshot".utf8) },
            uploadBackup: uploadBackup,
            waitForBackupDelay: waitForBackupDelay
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
