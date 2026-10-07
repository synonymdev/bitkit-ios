@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class UsdtWalletManagerTests: XCTestCase {
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

        let manager = UsdtWalletManager(storageDirectory: directory)
        async let first: Void = manager.wipe()
        async let second: Void = manager.wipe()
        _ = try await (first, second)
        for file in usdtFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(manager.address.isEmpty)
        XCTAssertTrue(manager.transfers.isEmpty)
        XCTAssertNil(manager.balance)
        do {
            _ = try await manager.quote(recipient: "0x1111111111111111111111111111111111111111", amount: "1", destination: .arbitrum)
            XCTFail("A wiped session must not reopen its wallet")
        } catch is CancellationError {}
    }
}
