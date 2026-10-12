@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class OnchainActivitySyncTests: XCTestCase {
    private let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("OnchainActivitySyncTests-\(UUID().uuidString)", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
        snapshotAppDefaults("activityDetachedContacts")
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

    func testSyncOverlappingSendKeepsOneAttributedActivityThroughConfirmation() async throws {
        let txid = String(repeating: "ab", count: 32)
        let contact = "pubky" + String(repeating: "y", count: 52)
        let lookupStarted = expectation(description: "Channel lookup started")
        let gate = LookupGate()
        let activity = Bitkit.ActivityService(coreService: .shared, channelLookup: { _, _, _ in
            if await gate.shouldWait() {
                lookupStarted.fulfill()
                await gate.wait()
            }
            return nil
        })
        let timestamp = UInt64(Date().timeIntervalSince1970) + 10
        var payment = LDKNode.PaymentDetails(
            id: String(repeating: "cd", count: 32),
            kind: .onchain(txid: txid, status: .unconfirmed),
            amountMsat: 5_000_000,
            feePaidMsat: 209_000,
            direction: .outbound,
            status: .succeeded,
            latestUpdateTimestamp: timestamp
        )
        let syncing = Task { try await activity.syncLdkNodePayments([payment]) }
        await fulfillment(of: [lookupStarted], timeout: 5)
        let created = await activity.createSentOnchainActivityFromSendResult(
            txid: txid, address: "bcrt1qrecipient", amount: 5000, fee: 209,
            feeRate: 2, contact: contact
        )
        XCTAssertTrue(created)
        await gate.release()
        try await syncing.value

        for confirmed in [false, true] {
            if confirmed {
                payment.kind = .onchain(
                    txid: txid,
                    status: .confirmed(blockHash: String(repeating: "ef", count: 32), height: 100, timestamp: timestamp)
                )
                payment.latestUpdateTimestamp = timestamp + 1
                try await activity.syncLdkNodePayments([payment])
            }
            let rows = try await activity.get(filter: .onchain, walletId: WalletScope.default)
            XCTAssertEqual(rows.count, 1)
            guard case let .onchain(row) = try XCTUnwrap(rows.first) else { return XCTFail("Expected onchain activity") }
            XCTAssertEqual(row.id, txid)
            XCTAssertEqual(row.txId, txid)
            XCTAssertEqual(row.contact, contact)
            XCTAssertEqual(row.value, 5000)
            XCTAssertEqual(row.fee, 209)
            XCTAssertEqual(row.feeRate, 2)
            XCTAssertEqual(row.address, "bcrt1qrecipient")
            XCTAssertEqual(row.confirmed, confirmed)
        }
    }
}

private actor LookupGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func shouldWait() -> Bool {
        defer { started = true }
        return !started
    }

    func wait() async {
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
