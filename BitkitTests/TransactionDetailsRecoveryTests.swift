@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class TransactionDetailsRecoveryTests: XCTestCase {
    private let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("TransactionDetailsRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    private let txid = String(repeating: "ab", count: 32)

    override func setUp() async throws {
        try await super.setUp()
        _ = Bitkit.CoreService.shared
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        _ = try initDb(basePath: database.path)
    }

    override func tearDown() async throws {
        await drainCoreServiceQueue()
        await repointCoreToAppStorage()
        try? FileManager.default.removeItem(at: database)
        try await super.tearDown()
    }

    func testStoredDetailsTakePrecedence() async throws {
        let stored = BitkitCore.TransactionDetails(walletId: WalletScope.default, txId: txid, amountSats: 123, inputs: [], outputs: [])
        try await Bitkit.ServiceQueue.background(.core) { try upsertTransactionDetails(detailsList: [stored]) }
        let activity = Bitkit.ActivityService(coreService: .shared, nodeTransactionLookup: { _ in
            XCTFail("Stored details must not query the node")
            return nil
        })

        let result = try await activity.getTransactionDetails(txid: txid)

        XCTAssertEqual(result, stored)
    }

    func testMissingDetailsReadLocalInputsAndOutputsWithoutWritingCache() async throws {
        let previous = String(repeating: "cd", count: 32)
        let activity = Bitkit.ActivityService(coreService: .shared, nodeTransactionLookup: { requested in
            XCTAssertEqual(requested, self.txid)
            return LDKNode.TransactionDetails(
                amountSats: -123,
                inputs: [.init(txid: previous, vout: 2, scriptsig: "00", witness: ["01"], sequence: 42)],
                outputs: [.init(scriptpubkey: "0014", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: "bcrt1qrecipient", value: 123, n: 0)]
            )
        })

        let result = try await activity.getTransactionDetails(txid: txid)
        let details = try XCTUnwrap(result)

        XCTAssertEqual(details.walletId, WalletScope.default)
        XCTAssertEqual(details.txId, txid)
        XCTAssertEqual(details.amountSats, -123)
        XCTAssertEqual(details.inputs, [.init(txid: previous, vout: 2, scriptsig: "00", witness: ["01"], sequence: 42)])
        XCTAssertEqual(details.outputs, [.init(
            scriptpubkey: "0014", scriptpubkeyType: "v0_p2wpkh", scriptpubkeyAddress: "bcrt1qrecipient", value: 123, n: 0
        )])
        let cached = try await Bitkit.ServiceQueue.background(.core) {
            try BitkitCore.getTransactionDetails(walletId: WalletScope.default, txId: self.txid)
        }
        XCTAssertNil(cached)
    }

    func testHardwareWalletNeverFallsBackToTheDefaultNode() async throws {
        let activity = Bitkit.ActivityService(coreService: .shared, nodeTransactionLookup: { _ in
            XCTFail("Hardware-wallet data must not come from the default wallet")
            return nil
        })

        let result = try await activity.getTransactionDetails(txid: txid, walletId: "hardware-wallet")

        XCTAssertNil(result)
    }

    func testInvalidTransactionIdDoesNotReachNodeBindings() async throws {
        let activity = Bitkit.ActivityService(coreService: .shared, nodeTransactionLookup: { _ in
            XCTFail("Invalid IDs must not reach the Rust transaction-ID converter")
            return nil
        })

        for invalid in ["", "ab", String(repeating: "z", count: 64), String(repeating: "Ａ", count: 64)] {
            let result = try await activity.getTransactionDetails(txid: invalid)
            XCTAssertNil(result)
        }
    }

    func testMissingNodeTransactionRemainsUnavailable() async throws {
        let activity = Bitkit.ActivityService(coreService: .shared, nodeTransactionLookup: { _ in nil })

        let result = try await activity.getTransactionDetails(txid: txid)

        XCTAssertNil(result)
    }
}
