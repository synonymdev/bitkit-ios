@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class UsdtRecoveryBackupTests: XCTestCase {
    private let emptyPayments = PaykitUsdtStateBackup(attempts: [], receipts: [])

    func testRecoveryDoesNotExportPaykitOrReplaceCompleteWalletBackup() async throws {
        let remote = RecoveryRemote()
        let original = Data("complete-wallet-backup".utf8)
        await remote.seed(key: "WALLET", data: original)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = BackupService(defaults: defaults, backupData: { _ in
            XCTFail("USDT recovery must not export unrelated Paykit state")
            throw UsdtError.NetworkUnavailable
        }, usdtRecoveryBackup: store(remote))
        try await service.persistUsdtRecoveryBackup(snapshot: "signed-operation")
        let saved = try await store(remote).snapshots()
        XCTAssertEqual(saved.map(\.usdtWallet), ["signed-operation"])
        let wallet = await remote.read("WALLET")
        XCTAssertEqual(wallet, original)
    }

    func testLostAcknowledgementAndRestartRetryTheSameImmutableRecord() async throws {
        let remote = RecoveryRemote()
        await remote.failNextAcknowledgement()
        do {
            try await store(remote).persist(snapshot: "same-signed-operation", paymentState: emptyPayments)
            XCTFail("A missing acknowledgement must fail the backup callback")
        } catch UsdtError.BackupUnavailable {}
        let restarted = store(remote)
        try await restarted.persist(snapshot: "same-signed-operation", paymentState: emptyPayments)
        let keys = await remote.list()
        XCTAssertEqual(keys.count, 1)
        let restored = try await restarted.snapshots()
        XCTAssertEqual(restored.map(\.usdtWallet), ["same-signed-operation"])
    }

    func testConcurrentWritersRetainBothRecoverySnapshots() async throws {
        let remote = RecoveryRemote()
        let first = store(remote)
        let second = store(remote)
        async let one: Void = first.persist(snapshot: "operation-one", paymentState: emptyPayments)
        async let two: Void = second.persist(snapshot: "operation-two", paymentState: emptyPayments)
        _ = try await (one, two)
        let snapshots = try await store(remote).snapshots()
        XCTAssertEqual(Set(snapshots.map(\.usdtWallet)), ["operation-one", "operation-two"])
    }

    func testUnknownVersionMissingRecordAndCorruptionFailClosed() async throws {
        for value in [Data("unknown".utf8), Data()] {
            let remote = RecoveryRemote()
            await remote.seed(key: "USDT_RECOVERY_V2_future", data: value)
            do { _ = try await store(remote).snapshots(); XCTFail("Unknown recovery versions must not be skipped") }
            catch UsdtError.InvalidBackup {}
        }
        let remote = RecoveryRemote()
        try await store(remote).persist(snapshot: "signed", paymentState: emptyPayments)
        let keys = await remote.list()
        let key = try XCTUnwrap(keys.first)
        await remote.seed(key: key, data: Data("corrupt".utf8))
        do { _ = try await store(remote).snapshots(); XCTFail("Corruption must stop restore") }
        catch UsdtError.InvalidBackup {}
        var missing = store(remote)
        missing.get = { _ in nil }
        do { _ = try await missing.snapshots(); XCTFail("Listed records must all be readable") }
        catch UsdtError.InvalidBackup {}
    }

    func testRestoreGateSurvivesManagerRestartAndBlocksNetworkRecovery() async throws {
        try UsdtRecoveryRestoreGate.begin()
        defer { try? UsdtRecoveryRestoreGate.complete() }
        for _ in 0 ..< 2 {
            let manager = UsdtWalletManager(loadCredentials: {
                XCTFail("No network wallet operation may start before recovery is complete")
                throw UsdtError.InvalidCredentials
            })
            XCTAssertFalse(manager.canRecoverTransfers)
            do { _ = try await manager.quoteMaximum(recipient: "recipient", destination: .arbitrum); XCTFail("Restore is pending") }
            catch UsdtError.BackupUnavailable {}
            await manager.refresh()
        }
        try UsdtRecoveryRestoreGate.complete()
        XCTAssertTrue(UsdtWalletManager().canRecoverTransfers)
    }

    func testInterruptedMigrationReplaysLegacyAndJournalBeforeClearingRestoreGate() async throws {
        let remote = RecoveryRemote()
        try await store(remote).persist(snapshot: "signed-one", paymentState: emptyPayments)
        try await store(remote).persist(snapshot: "signed-two", paymentState: emptyPayments)
        defer { try? UsdtRecoveryRestoreGate.complete() }
        for failureAt in 0 ..< 6 {
            try UsdtRecoveryRestoreGate.begin()
            var step = 0
            var restored = Set<String>()
            do {
                try await store(remote).restore(legacyWallet: "legacy", legacyPaymentState: emptyPayments,
                                                restoreWallet: { value in
                                                    defer { step += 1 }
                                                    if step == failureAt {
                                                        throw UsdtError.BackupUnavailable
                                                    }
                                                    restored.insert(value)
                                                }, restorePayments: { _ in
                                                    defer { step += 1 }
                                                    if step == failureAt {
                                                        throw UsdtError.BackupUnavailable
                                                    }
                                                })
                XCTFail("Injected restore failure must propagate")
            } catch UsdtError.BackupUnavailable {}
            XCTAssertTrue(UsdtRecoveryRestoreGate.isPending)
            let restarted = store(remote)
            try await restarted.restore(legacyWallet: "legacy", legacyPaymentState: emptyPayments,
                                        restoreWallet: { restored.insert($0) }, restorePayments: { _ in })
            try UsdtRecoveryRestoreGate.complete()
            XCTAssertEqual(restored, ["legacy", "signed-one", "signed-two"])
            XCTAssertFalse(UsdtRecoveryRestoreGate.isPending)
        }
    }

    func testAndroidAndIosEnvelopeEncodingsRestoreWithTheirOriginalContentHashes() async throws {
        let remote = RecoveryRemote()
        await remote.seed(
            key: "USDT_RECOVERY_V1_c3b84c73c7a42be59f530edc24ed338ebb15475f10229a7c3fe49125beb532c2",
            data: Data(#"{"version":1,"usdtWallet":"{\"identity\":\"42161:0x1111111111111111111111111111111111111111\",\"transfers\":[]}","paykitUsdtState":{"attempts":[],"receipts":[]}}"#
                .utf8)
        )
        await remote.seed(
            key: "USDT_RECOVERY_V1_54006dcc1f1a5af1d8c31954fee58bc3ab35f5c3c0d3cb81b63e4fd7c3ea9c5c",
            data: Data(#"{"paykitUsdtState":{"attempts":[],"receipts":[]},"usdtWallet":"{\"identity\":\"42161:0x1111111111111111111111111111111111111111\",\"transfers\":[]}","version":1}"#
                .utf8)
        )
        let restored = try await store(remote).snapshots()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(Set(restored.map(\.usdtWallet)), [#"{"identity":"42161:0x1111111111111111111111111111111111111111","transfers":[]}"#])
        XCTAssertTrue(restored.allSatisfy { $0.paykitUsdtState.attempts.isEmpty && $0.paykitUsdtState.receipts.isEmpty })
    }

    func testFailedMigrationRetainsLegacyPayloadAndBlocksReplacementAcrossRestart() async throws {
        defer { try? UsdtRecoveryRestoreGate.complete() }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"version":1,"createdAt":1,"transfers":[],"usdtWallet":"legacy-signed-operation"}"#.utf8)
        var downloads = 0
        let recovery = UsdtRecoveryBackupStore(
            keys: { throw UsdtError.NetworkUnavailable },
            get: { key in
                XCTAssertEqual(key, BackupCategory.wallet.rawValue)
                downloads += 1
                guard downloads == 1 else { throw UsdtError.NetworkUnavailable }
                return legacy
            }
        )
        for _ in 0 ..< 2 {
            let connection = ConnectionRecoveryService(
                owner: { .init(walletIndex: 0, network: "regtest", binding: "legacy-test-wallet") },
                load: { nil }, store: { _ in XCTFail("No connection correction is being saved") },
                clear: { XCTFail("No connection correction is being completed") }, defaults: defaults
            )
            let service = BackupService(defaults: defaults, connectionRecovery: connection, backupData: { _ in
                XCTFail("A partial wallet must not replace the retained backup")
                return Data()
            }, usdtRecoveryBackup: recovery, uploadBackup: { _, _ in
                XCTFail("A replacement upload must remain blocked")
            })
            do {
                try await service.restoreUsdtRecoveryAfterLegacyMigration()
                XCTFail("The journal is unavailable")
            } catch UsdtError.NetworkUnavailable {}
            XCTAssertEqual(try UsdtRecoveryRestoreGate.begin(), legacy)
            XCTAssertTrue(service.hasPendingWalletRestore())
            do {
                try await service.persistWalletBackup()
                XCTFail("Incomplete restoration must block replacement")
            } catch UsdtError.BackupUnavailable {}
            service.setWiping(true)
            await service.stopObservingBackups()
        }
        XCTAssertEqual(downloads, 1)
    }

    private func store(_ remote: RecoveryRemote) -> UsdtRecoveryBackupStore {
        UsdtRecoveryBackupStore(put: { try await remote.write($0, data: $1) },
                                keys: { await remote.list() }, get: { await remote.read($0) })
    }
}

private actor RecoveryRemote {
    private var records: [String: Data] = [:]
    private var failAcknowledgement = false

    func seed(key: String, data: Data) {
        records[key] = data
    }

    func list() -> [String] {
        Array(records.keys)
    }

    func read(_ key: String) -> Data? {
        records[key]
    }

    func failNextAcknowledgement() {
        failAcknowledgement = true
    }

    func write(_ key: String, data: Data) throws {
        records[key] = data
        if failAcknowledgement {
            failAcknowledgement = false
            throw UsdtError.BackupUnavailable
        }
    }
}
