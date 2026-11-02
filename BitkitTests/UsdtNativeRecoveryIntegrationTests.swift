@testable import Bitkit
import BitkitCore
import VssRustClientFfi
import XCTest

/// Opt-in protocol fixture using a public seed, isolated SQLite files and real encrypted VSS transport.
@MainActor
final class UsdtNativeRecoveryIntegrationTests: XCTestCase {
    private let mnemonic = "test test test test test test test test test test test junk"

    func testEncryptedRecoveryAgainstLocalProtocolFixture() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["BITKIT_USDT_RECOVERY_FIXTURE_URL"] else {
            throw XCTSkip("Set BITKIT_USDT_RECOVERY_FIXTURE_URL to an owned local recovery protocol fixture")
        }
        let address = try XCTUnwrap(URLComponents(string: fixture))
        guard address.scheme == "http", address.host == "127.0.0.1", let port = address.port,
              (1 ... 65535).contains(port), address.path.isEmpty, address.user == nil,
              address.password == nil, address.query == nil, address.fragment == nil
        else {
            XCTFail("The recovery protocol fixture must be an explicit loopback address and port")
            return
        }
        let driver: [String: Any]
        do { driver = try await request("\(fixture)/ios-driver/control") }
        catch { throw XCTSkip("Requires the owned local recovery protocol fixture") }
        guard let scenario = driver["scenario"] as? String, let phase = driver["phase"] as? String else {
            throw XCTSkip("The fixture must select a scenario and process phase")
        }
        XCTAssertTrue(scenario.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        guard try Keychain.loadString(key: .bip39Mnemonic(index: 0)) == nil else {
            throw XCTSkip("Use a disposable test installation without an application wallet")
        }
        let url = "\(fixture)/\(scenario)"
        let phaseStart = try await events(url).count
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("usdt-recovery-\(scenario)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeId = try vssDeriveStoreId(prefix: "bitkit_v1_regtest", mnemonic: mnemonic, passphrase: nil)
        try await vssNewClientWithLnurlAuth(baseUrl: url, storeId: storeId, mnemonic: mnemonic,
                                            passphrase: nil, lnurlAuthServerUrl: "\(url)/auth")
        let store = UsdtRecoveryBackupStore(
            put: { key, value in _ = try await vssStore(key: key, value: value) },
            keys: { try await vssListKeys(prefix: nil).map(\.key) },
            get: { try await vssGet(key: $0)?.value }
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "usdt-recovery-\(scenario)"))
        let service = BackupService(defaults: defaults, backupData: { category in
            XCTAssertEqual(category, .usdt, "Ordinary USDT recovery must never export unrelated Paykit state")
            throw UsdtError.NetworkUnavailable
        }, usdtRecoveryBackup: store, waitForBackupDelay: {
            try await Task.sleep(nanoseconds: 120_000_000_000)
        })
        defer { service.setWiping(true) }
        let callback = NativeRecoveryBackup { snapshot in
            do { try await service.persistUsdtRecoveryBackup(snapshot: snapshot) }
            catch { throw UsdtError.BackupUnavailable }
        }
        let wallet = try UsdtWallet(
            address: usdtAddress(mnemonic: mnemonic, passphrase: nil),
            storagePath: directory.appendingPathComponent(phase == "restore" ? "restored.sqlite" : "original.sqlite").path,
            rpcUrl: "\(url)/rpc", bundlerUrl: "\(url)/rpc", bridgeUrl: nil, backup: callback
        )
        let saved = directory.appendingPathComponent("signed-snapshot.json")
        if phase == "prepare" {
            XCTAssertTrue(try wallet.history().isEmpty, "Each scenario needs a new isolated database")
            let configured = try await request("\(url)/control")
            let mode = try XCTUnwrap(configured["mode"] as? String)
            _ = try await request("\(url)/control", body: ["faultMode": mode])
            _ = try await request("\(url)/control", body: ["mode": "accept"])
            _ = try await vssStore(key: "WALLET", value: Data("complete-wallet-backup".utf8))
            let initialWalletBackup = try await vssGet(key: "WALLET")
            XCTAssertEqual(initialWalletBackup?.value, Data("complete-wallet-backup".utf8))
            _ = try await request("\(url)/control", body: ["mode": mode])
            let quote = try await wallet.quoteTransfer(recipient: "0x1111111111111111111111111111111111111111",
                                                       amount: 1_000_000, destination: .arbitrum)
            let original = try await expectBackupFailure(wallet, store: store, url: url, mode: mode) {
                _ = try await wallet.send(quoteId: quote.id, mnemonic: mnemonic, passphrase: nil)
            }
            try Data(original.utf8).write(to: saved, options: .atomic)
            _ = try await request("\(url)/control", body: ["expectedSnapshot": original])
            _ = try await request("\(url)/control", body: ["advance": 3])
            for _ in 0 ..< 2 {
                let snapshot = try await expectBackupFailure(wallet, store: store, url: url, mode: mode) {
                    _ = try await wallet.refreshTransfers()
                }
                XCTAssertEqual(try signedOperation(snapshot), try signedOperation(original))
            }
            let state = try await request("\(url)/control")
            XCTAssertTrue(try XCTUnwrap(state["operations"] as? [Any]).isEmpty)
            XCTAssertEqual(try wallet.history().count, 1)
        } else {
            let configured = try await request("\(url)/control")
            let original = try XCTUnwrap(configured["expectedSnapshot"] as? String)
            let mode = try XCTUnwrap(configured["faultMode"] as? String)
            _ = try await request("\(url)/control", body: ["mode": mode, "advance": 3])
            if phase == "restore" {
                XCTAssertTrue(try wallet.history().isEmpty)
                try await store.restore(legacyWallet: nil, legacyPaymentState: nil,
                                        restoreWallet: { try await wallet.restoreBackup(snapshot: $0) },
                                        restorePayments: { state in XCTAssertTrue(state.attempts.isEmpty && state.receipts.isEmpty) })
            } else {
                XCTAssertEqual(phase, "resume")
            }
            XCTAssertEqual(try signedOperation(wallet.exportBackup()), try signedOperation(original))
            let failedSnapshot = try await expectBackupFailure(wallet, store: store, url: url, mode: mode) {
                _ = try await wallet.refreshTransfers()
            }
            XCTAssertEqual(try signedOperation(failedSnapshot), try signedOperation(original))
            let failedEvents = try await events(url)
            XCTAssertFalse(failedEvents.dropFirst(phaseStart).contains { $0["type"] as? String == "broadcast-attempt" })
            _ = try await request("\(url)/control", body: ["mode": "accept", "advance": 3])
            _ = try await wallet.refreshTransfers()
            _ = try await wallet.refreshTransfers()
            let state = try await request("\(url)/control")
            let operations = try XCTUnwrap(state["operations"] as? [[String: Any]])
            XCTAssertEqual(operations.count, 1, "Retries may only resubmit the original signed operation")
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(operations.first?["operation"]), options: .sortedKeys),
                           try signedOperation(original))
            let allEvents = try XCTUnwrap(state["events"] as? [[String: Any]])
            let initialKeys = try XCTUnwrap(allEvents.first { $0["type"] as? String == "backup-acknowledged" }?["keys"] as? [String])
            let phaseEvents = Array(allEvents.dropFirst(phaseStart))
            let firstAttempt = try XCTUnwrap(phaseEvents.firstIndex { $0["type"] as? String == "broadcast-attempt" })
            XCTAssertTrue(phaseEvents[..<firstAttempt].contains {
                $0["type"] as? String == "backup-acknowledged" && $0["keys"] as? [String] != initialKeys
            }, "This process must acknowledge its recovery record before attempting submission")
            XCTAssertTrue(phaseEvents.contains { $0["type"] as? String == "broadcast" })
            for attempt in phaseEvents.filter({ $0["type"] as? String == "broadcast-attempt" }) {
                XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(attempt["operation"]), options: .sortedKeys),
                               try signedOperation(original))
            }
            let completeWalletBackup = try await vssGet(key: "WALLET")
            XCTAssertEqual(completeWalletBackup?.value, Data("complete-wallet-backup".utf8))
            XCTAssertEqual(try wallet.history().count, 1)
        }
        let attachment = try XCTAttachment(data: Data(wallet.exportBackup().utf8), uniformTypeIdentifier: "public.json")
        attachment.name = "\(scenario)-\(phase)-public-fixture-snapshot"
        attachment.lifetime = .keepAlways
        add(attachment)
        await service.stopObservingBackups()
    }

    private func events(_ url: String) async throws -> [[String: Any]] {
        let state = try await request("\(url)/control")
        return try XCTUnwrap(state["events"] as? [[String: Any]])
    }

    private func expectBackupFailure(_ wallet: UsdtWallet, store: UsdtRecoveryBackupStore, url: String,
                                     mode: String, operation: () async throws -> Void) async throws -> String
    {
        let before = try await request("\(url)/control")
        let checkpoint = try XCTUnwrap(before["events"] as? [Any]).count
        do { try await operation(); XCTFail("Unacknowledged backup must prevent broadcast") }
        catch UsdtError.BackupUnavailable {}
        let snapshot = try wallet.exportBackup()
        let after = try await request("\(url)/control")
        let newEvents = try XCTUnwrap(after["events"] as? [[String: Any]]).dropFirst(checkpoint)
        let fault = mode == "reject" ? "backup-rejected" : "backup-ack-dropped"
        XCTAssertTrue(newEvents.contains { $0["type"] as? String == fault }, "Every retry must reach the requested VSS fault")
        XCTAssertFalse(newEvents.contains { $0["type"] as? String == "broadcast-attempt" })
        XCTAssertFalse(newEvents.contains { $0["type"] as? String == "backup-acknowledged" })
        if mode == "reject" {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(before["stores"]), options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: XCTUnwrap(after["stores"]), options: .sortedKeys))
        } else {
            XCTAssertEqual(mode, "commit-drop")
            let records = try await store.snapshots()
            XCTAssertFalse(records.isEmpty, "The server committed encrypted recovery data despite losing its acknowledgement")
            for record in records {
                XCTAssertEqual(try signedOperation(record.usdtWallet), try signedOperation(snapshot))
            }
        }
        return snapshot
    }

    private func signedOperation(_ snapshot: String) throws -> Data {
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any])
        let transfer = try XCTUnwrap((payload["transfers"] as? [[String: Any]])?.first)
        let plan = try XCTUnwrap(transfer["plan"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(plan["operation"]), options: .sortedKeys)
    }

    private func request(_ address: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = try URLRequest(url: XCTUnwrap(URL(string: address)))
        request.timeoutInterval = 3
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class NativeRecoveryBackup: UsdtBackup, @unchecked Sendable {
    private let persistSnapshot: @MainActor (String) async throws -> Void

    init(_ persist: @escaping @MainActor (String) async throws -> Void) {
        persistSnapshot = persist
    }

    func persist(snapshot: String) async throws {
        try await persistSnapshot(snapshot)
    }
}
