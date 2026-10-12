@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class UsdtWalletManagerTests: XCTestCase {
    func testNativeSubmissionRejectsAnExpiredPreciseDeadlineWithoutCreatingATransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try UsdtWallet(
            address: "0x1111111111111111111111111111111111111111",
            storagePath: directory.appendingPathComponent("usdt.sqlite").path,
            rpcUrl: "http://127.0.0.1:1", bundlerUrl: "http://127.0.0.1:1", bridgeUrl: nil,
            backup: UnavailableUsdtBackup()
        )
        let deadline = try XCTUnwrap(PaykitPreciseInstant(timestamp: "2020-01-01T00:00:00.123456789Z"))
        do {
            _ = try await wallet.sendWithDeadline(
                quoteId: "expired-request", mnemonic: "test test test test test test test test test test test junk",
                passphrase: nil, submissionDeadline: deadline.timestamp
            )
            XCTFail("An expired payment must not be submitted")
        } catch {
            guard let error = error as? UsdtError, case .SubmissionDeadlineExpired = error else { throw error }
            XCTAssertEqual(UsdtWalletManager.message(for: error), t("wallet__payment_request_expired"))
        }
        XCTAssertTrue(try wallet.history().isEmpty)
    }

    func testFeeCollectionFailureIsActionableWithoutMisclassifyingOtherRejections() {
        XCTAssertEqual(UsdtWalletManager.message(for: UsdtError.TransactionRejected(reason: "Paymaster fee collection failed")),
                       t("usdt__error_fee_collection"))
        XCTAssertEqual(UsdtWalletManager.message(for: UsdtError.TransactionRejected(reason: "Provider rejected the request")),
                       t("usdt__error_rejected"))
        XCTAssertEqual(UsdtWalletManager.message(for: UsdtError.InsufficientBalance), t("usdt__error_balance"))
    }

    func testOnlyNewConfirmedReceiptsCelebrateAfterInitialSync() {
        let old = transfer("old")
        let incoming = transfer("new")
        let pending = transfer("pending", status: .pending)
        let failed = transfer("failed", status: .failed)
        let outgoing = transfer("sent", incoming: false)
        let empty = transfer("zero", amount: 0)
        XCTAssertTrue(UsdtWalletManager.newIncomingTransfers(previous: nil, current: [old]).isEmpty)
        let current = [old, incoming, pending, failed, outgoing, empty]
        XCTAssertEqual(UsdtWalletManager.newIncomingTransfers(previous: [old], current: current), [incoming])
        XCTAssertTrue(UsdtWalletManager.newIncomingTransfers(previous: current, current: current).isEmpty)
        let confirmed = transfer("pending")
        XCTAssertEqual(UsdtWalletManager.newIncomingTransfers(previous: current, current: current + [confirmed]), [confirmed])
    }

    func testLinkedOrderStatusAndErrorSupersedeDepositStateTogether() {
        let deposit = UsdtDeposit(id: "deposit", network: "solana", asset: "USDT", amount: 100, sourceTx: "tx", status: "held",
                                  code: "standing_route_unavailable", refundTx: nil)
        let cases: [(String?, String?, String)] = [
            ("completed", nil, "usdt__confirmed"),
            (nil, deposit.code, "usdt__deposit_needs_attention"),
            ("unknown", nil, "usdt__deposit_needs_attention"),
            ("pending", nil, "usdt__pending"),
            ("processing", nil, "usdt__pending"),
            ("refunded", nil, "usdt__deposit_refunded"),
            ("failed", "order_error", "usdt__deposit_needs_attention"),
        ]
        for (status, code, key) in cases {
            let order = status.map { UsdtDepositOrder(status: $0, amountIn: 100, amountOut: 90, destinationTx: nil, refundTx: nil, code: code) }
            let detail = UsdtDepositDetail(deposit: deposit, order: order)
            XCTAssertEqual(detail.statusText, t(key))
            XCTAssertEqual(detail.statusCode, code)
        }
    }

    func testDepositStatusDistinguishesRefundProgressFromActionableErrors() {
        let cases: [(String, String?, String)] = [
            ("completed", "standing_route_unavailable", "usdt__confirmed"),
            ("refunded", "xchain_amount_too_small", "usdt__deposit_refunded"),
            ("refund_requested", "standing_refund_pending", "usdt__deposit_refunding"),
            ("refunding", "standing_refund_pending", "usdt__deposit_refunding"),
            ("refund_requested", "standing_tron_refund_requires_operator", "usdt__deposit_needs_attention"),
            ("refunding", "refund_error", "usdt__deposit_needs_attention"),
            ("pending", "standing_route_unavailable", "usdt__deposit_needs_attention"),
            ("below_minimum", "xchain_amount_too_small", "usdt__deposit_needs_attention"),
        ]
        for (status, code, key) in cases {
            let deposit = UsdtDeposit(id: "deposit", network: "bsc", asset: "USDT", amount: 100, sourceTx: "tx", status: status,
                                      code: code, refundTx: nil)
            let order = UsdtDepositOrder(status: status, amountIn: 100, amountOut: 90, destinationTx: nil, refundTx: nil, code: code)
            XCTAssertEqual(deposit.statusText, t(key), status)
            for linkedOrder in [nil, order] {
                let detail = UsdtDepositDetail(deposit: deposit, order: linkedOrder)
                XCTAssertEqual(detail.statusText, t(key), status)
                XCTAssertEqual(detail.statusCode, code, status)
            }
        }
    }

    private func transfer(_ id: String, incoming: Bool = true, status: UsdtTransferStatus = .confirmed, amount: UInt64 = 1_000_000) -> UsdtTransfer {
        UsdtTransfer(
            id: id,
            txHash: status == .pending ? nil : id,
            userOperationHash: nil,
            bridgeGuid: nil,
            orchestra: nil,
            recipient: "recipient",
            destination: .arbitrum,
            amount: amount,
            receivedAmount: amount,
            fee: nil,
            isIncoming: incoming,
            status: status,
            timestamp: 1
        )
    }

    func testWalletReadsCredentialsOncePerSessionAndUsesFreshCredentialsAfterWipe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mnemonic = "test test test test test test test test test test test junk"
        var credentialReads = 0
        let manager = UsdtWalletManager(storageDirectory: directory, loadCredentials: {
            credentialReads += 1
            return (mnemonic, nil)
        })
        async let first = manager.paymentEndpoint()
        async let second = manager.paymentEndpoint()
        let (firstEndpoint, secondEndpoint) = try await (first, second)
        XCTAssertEqual(firstEndpoint.value, secondEndpoint.value)
        _ = try await manager.storedTransfer("missing")
        let snapshot = try await manager.backupSnapshot()
        let backup = try XCTUnwrap(snapshot)
        try await manager.restoreBackup(backup)
        XCTAssertEqual(credentialReads, 1)

        try await manager.wipe()
        do {
            _ = try await manager.paymentEndpoint()
            XCTFail("A wiped session must not read credentials or reopen its wallet")
        } catch is CancellationError {}
        XCTAssertEqual(credentialReads, 1)

        let restored = UsdtWalletManager(storageDirectory: directory, loadCredentials: {
            credentialReads += 1
            return (mnemonic, "restored passphrase")
        })
        let restoredEndpoint = try await restored.paymentEndpoint()
        XCTAssertNotEqual(restoredEndpoint.value, firstEndpoint.value)
        XCTAssertEqual(credentialReads, 2)
        try await restored.wipe()
    }

    func testWipeRemovesUsdtPersistenceAndStopsSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let usdtFiles = ["usdt-wipe-test.sqlite", "usdt-wipe-test.sqlite-wal", "usdt-wipe-test.sqlite-shm"]
            .map { directory.appendingPathComponent($0) }
        let unrelated = directory.appendingPathComponent("unrelated-wipe-test.txt")
        defer { try? FileManager.default.removeItem(at: unrelated) }
        for file in usdtFiles + [unrelated] {
            try Data("private payment data".utf8).write(to: file)
        }

        let initializationStarted = expectation(description: "credential read started")
        var resumeInitialization: CheckedContinuation<Void, Never>?
        let manager = UsdtWalletManager(storageDirectory: directory, loadCredentials: {
            await withCheckedContinuation { continuation in
                resumeInitialization = continuation
                initializationStarted.fulfill()
            }
            return ("test test test test test test test test test test test junk", nil)
        })
        let endpoint = Task { try await manager.paymentEndpoint() }
        await fulfillment(of: [initializationStarted], timeout: 2)
        let wipeStarted = expectation(description: "wipe started during initialization")
        let first = Task {
            wipeStarted.fulfill()
            try await manager.wipe()
        }
        await fulfillment(of: [wipeStarted], timeout: 2)
        do {
            _ = try await manager.paymentEndpoint()
            XCTFail("A wipe must block further wallet operations")
        } catch is CancellationError {}
        let second = Task { try await manager.wipe() }
        resumeInitialization?.resume()
        _ = try await endpoint.value
        _ = try await (first.value, second.value)
        for file in usdtFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [unrelated.lastPathComponent])
        XCTAssertTrue(manager.address.isEmpty)
        XCTAssertTrue(manager.transfers.isEmpty)
        XCTAssertNil(manager.balance)
        do {
            _ = try await manager.quote(recipient: "0x1111111111111111111111111111111111111111", amount: "1", destination: .arbitrum)
            XCTFail("A wiped session must not reopen its wallet")
        } catch is CancellationError {}
    }
}

private final class UnavailableUsdtBackup: UsdtBackup {
    func persist(snapshot _: String) async throws {
        throw UsdtError.BackupUnavailable
    }
}
