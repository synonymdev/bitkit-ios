@testable import Bitkit
import Combine
import Paykit
import XCTest

@MainActor
final class BackupForegroundRecoveryTests: XCTestCase {
    func testForegroundRecoversEveryPendingCategoryWithoutStaleAlert() async throws {
        let fixture = try Fixture(categories: BackupCategory.allCases.filter { $0 != .lightningConnections })
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let service = fixture.service(uploadBackup: { key, _ in await uploads.record(key) })
        await startAfterPendingJobsSettle(service, categories: fixture.categories)
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
        let fixture = try Fixture(categories: [.usdt, .widgets])
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let failed = expectation(description: "USDT retry failed")
        let started = expectation(description: "Widgets retry started")
        let (uploadGate, releaseUpload) = AsyncStream<Void>.makeStream()
        defer { releaseUpload.finish() }
        let service = fixture.service(uploadBackup: { key, _ in
            await uploads.record(key)
            if key == BackupCategory.usdt.rawValue {
                throw URLError(.notConnectedToInternet)
            }
            guard key == BackupCategory.widgets.rawValue else { return }
            started.fulfill()
            for await _ in uploadGate {}
        })
        await startAfterPendingJobsSettle(service, categories: fixture.categories)
        let statusSubscription = service.backupStatusesPublisher
            .map { $0[.usdt]?.running == true }
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

        XCTAssertEqual(service.getBackupStatus(category: .usdt).required, fixture.required)
        XCTAssertTrue(service.getBackupStatus(category: .usdt).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .widgets).isRequired)

        let repeatedAlert = expectation(description: "Foreground retry must preserve notification cooldown")
        repeatedAlert.isInverted = true
        failureSubscription = service.backupFailurePublisher.sink { _ in repeatedAlert.fulfill() }
        service.setAppActive(false)
        await service.setAppActive(true)?.value
        await fulfillment(of: [repeatedAlert], timeout: 0.2)
        failureSubscription.cancel()
        let recorded = await uploads.counts
        XCTAssertEqual(recorded[BackupCategory.usdt.rawValue], 2)
        XCTAssertEqual(recorded[BackupCategory.widgets.rawValue], 1)
        XCTAssertEqual(service.getBackupStatus(category: .usdt).required, fixture.required)
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testForegroundDoesNotDuplicateRunningOrScheduledBackups() async throws {
        let fixture = try Fixture(categories: [])
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
        await startAfterPendingJobsSettle(service, categories: fixture.categories)
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

    func testObservationRestartRetainsAndRecoversPendingBackup() async throws {
        let fixture = try Fixture(categories: [.settings])
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let service = fixture.service(uploadBackup: { key, _ in await uploads.record(key) })

        for _ in 0 ..< 8 {
            await startAfterPendingJobsSettle(service, categories: fixture.categories)
            await service.stopObservingBackups()

            let status = service.getBackupStatus(category: .settings)
            XCTAssertTrue(status.isRequired)
            XCTAssertEqual(status.required, fixture.required)
            XCTAssertFalse(status.running)
        }

        await startAfterPendingJobsSettle(service, categories: fixture.categories)
        await service.setAppActive(true)?.value

        let recorded = await uploads.counts
        XCTAssertEqual(recorded[BackupCategory.settings.rawValue], 1)
        XCTAssertFalse(service.getBackupStatus(category: .settings).isRequired)
        XCTAssertFalse(service.getBackupStatus(category: .settings).running)
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testStoppingRecoveryRetainsPendingBackupAndDoesNotUpload() async throws {
        let fixture = try Fixture(categories: [.settings])
        defer { fixture.removeDefaults() }
        let capturing = expectation(description: "Foreground backup capture started")
        let cancelled = expectation(description: "Stop cancels the captured operation")
        let stoppedEarly = expectation(description: "Stop must drain non-cooperative capture")
        stoppedEarly.isInverted = true
        let gate = CaptureGate()
        let service = BackupService(defaults: fixture.defaults, backupData: { _ in
            await withTaskCancellationHandler {
                await gate.wait(started: capturing)
            } onCancel: { cancelled.fulfill() }
            return Data("isolated-snapshot".utf8)
        }, uploadBackup: { _, _ in XCTFail("Stopped recovery must not upload") }, waitForBackupDelay: { throw CancellationError() })
        await startAfterPendingJobsSettle(service, categories: fixture.categories)

        let recovery = service.setAppActive(true)
        await fulfillment(of: [capturing], timeout: 2)
        service.setWiping(true)
        let stop = Task {
            await service.stopObservingBackups()
            if await gate.isHeld {
                stoppedEarly.fulfill()
            }
        }
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [stoppedEarly], timeout: 0.1)
        await gate.release()
        await stop.value
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
        await startAfterPendingJobsSettle(service, categories: fixture.categories)

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

    func testConcurrentSubscriptionRegistrationAndCancellationRetainsEveryCancellation() {
        let subscriptions = BackupObservationSubscriptions()
        let cancellations = CancellationRecorder()

        DispatchQueue.concurrentPerform(iterations: 256) { index in
            subscriptions.store(AnyCancellable { cancellations.record() })
            if index.isMultiple(of: 8) {
                subscriptions.cancelAll()
            }
        }
        subscriptions.cancelAll()

        XCTAssertEqual(cancellations.count, 256)
    }

    func testSubscriptionCancellationCanRegisterAnotherSubscription() {
        let subscriptions = BackupObservationSubscriptions()
        let cancellations = CancellationRecorder()
        subscriptions.store(AnyCancellable {
            cancellations.record()
            subscriptions.store(AnyCancellable { cancellations.record() })
        })

        subscriptions.cancelAll()
        XCTAssertEqual(cancellations.count, 1)
        subscriptions.cancelAll()
        XCTAssertEqual(cancellations.count, 2)
    }

    func testForegroundRetriesUsdtIndependentlyOfCompleteWalletRestore() async throws {
        let fixture = try Fixture(categories: [.wallet, .usdt])
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let service = fixture.service(uploadBackup: { key, _ in await uploads.record(key) })
        await startAfterPendingJobsSettle(service, categories: fixture.categories)
        service.setRestoring(true)

        await service.setAppActive(true)?.value

        let recorded = await uploads.counts
        XCTAssertEqual(recorded, [BackupCategory.usdt.rawValue: 1])
        XCTAssertFalse(service.getBackupStatus(category: .usdt).isRequired)
        XCTAssertTrue(service.getBackupStatus(category: .wallet).isRequired)
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    func testForegroundTemporaryFailureResumesBoundedRetryWithoutAnotherActivation() async throws {
        let fixture = try Fixture(categories: [.settings])
        defer { fixture.removeDefaults() }
        let uploads = UploadRecorder()
        let delays = UploadRecorder()
        let completed = expectation(description: "Foreground failure resumes the pending backup")
        let service = BackupService(defaults: fixture.defaults, backupData: { _ in Data("snapshot".utf8) }, uploadBackup: { key, _ in
            await uploads.record(key)
            let counts = await uploads.counts
            if counts[key] == 1 {
                throw PaykitError.ConcurrentUpdate(code: "concurrent_update", context: "held lease")
            }
        }, waitForBackupDelay: {
            throw CancellationError()
        }, waitForTemporaryFailureDelay: { delay in
            await delays.record(String(delay))
        })
        await startAfterPendingJobsSettle(service, categories: fixture.categories)
        let subscription = service.backupStatusesPublisher
            .filter { $0[.settings].map { !$0.isRequired && !$0.running } == true }
            .first().sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        await service.setAppActive(true)?.value
        await fulfillment(of: [completed], timeout: 2)

        let recorded = await uploads.counts
        let waited = await delays.counts
        XCTAssertEqual(recorded, [BackupCategory.settings.rawValue: 2])
        XCTAssertEqual(waited, ["10000000000": 1])
        XCTAssertFalse(service.getBackupStatus(category: .settings).isRequired)
        service.setAppActive(false)
        await service.stopObservingBackups()
    }

    private func startAfterPendingJobsSettle(_ service: BackupService, categories: [BackupCategory]) async {
        let settled = categories.map { expectation(description: "Initial \($0.rawValue) scheduling settled") }
        let subscriptions = zip(categories, settled).map { category, completed in
            service.backupStatusesPublisher
                .map { $0[category]?.running == true }
                .removeDuplicates()
                .drop(while: { !$0 })
                .filter { !$0 }
                .first().sink { _ in completed.fulfill() }
        }
        await service.startObservingBackups()?.value
        if !settled.isEmpty {
            await fulfillment(of: settled, timeout: 2)
        }
        subscriptions.forEach { $0.cancel() }
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
        await startAfterPendingJobsSettle(service, categories: fixture.categories)
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
        await startAfterPendingJobsSettle(service, categories: fixture.categories)
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

private final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

    var count: Int {
        lock.withLock { cancellations }
    }

    func record() {
        lock.withLock { cancellations += 1 }
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

private actor CaptureGate {
    private(set) var isHeld = true
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(started: XCTestExpectation) async {
        guard isHeld else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        isHeld = false
        continuation?.resume()
        continuation = nil
    }
}
