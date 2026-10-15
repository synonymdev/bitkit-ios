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
                    if changeDuringCapture, shouldChange { service.markBackupRequired(category: .wallet) }
                    return Data("snapshot".utf8)
                },
                uploadBackup: { _, _ in
                    if !changeDuringCapture, shouldChange { service.markBackupRequired(category: .wallet) }
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
                if captures <= 3 { changes.send() }
                return Data("snapshot-\(captures)".utf8)
            }
        }, uploadBackup: { _, data in
            uploads.append(data)
            if uploads.count == 1 { service.markBackupRequired(category: .wallet) }
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
                    if identityChanged { throw PubkyServiceError.identityChanged }
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
                    if attempts == 1 { firstAttempts.fulfill() } else { repeatedAttempt.fulfill() }
                    if failure == 0 { throw PubkyServiceError.identityChanged }
                    if failure == 1 { throw OnchainSendAttemptError.unresolved }
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
                if attempts == 3 { withUnsafeCurrentTask { $0?.cancel() } }
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
