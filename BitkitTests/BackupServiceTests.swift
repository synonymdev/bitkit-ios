@testable import Bitkit
import Combine
import Paykit
import XCTest

@MainActor
final class BackupServiceTests: XCTestCase {
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
