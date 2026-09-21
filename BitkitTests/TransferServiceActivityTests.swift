@testable import Bitkit
import BitkitCore
import XCTest

/// Regression coverage for the hardware-wallet pending transfer activity. `OnchainActivity.channelId`
/// must hold the LDK `channelId.description` (BOLT id) — it is matched that way by
/// `ChannelDetailsViewModel.findChannel` — never the Blocktank order's short channel id. Storing the
/// SCID there breaks the Connection/channel lookup; the correct BOLT id is set later by
/// `markOnchainActivityAsTransfer` during `syncTransferStates`.
///
/// App types are `Bitkit.`-qualified because some services are also compiled into the test target,
/// so unqualified names would resolve to the duplicate and mismatch `Bitkit.TransferService`.
final class TransferServiceActivityTests: XCTestCase {
    private let testDbPath = NSTemporaryDirectory()
    private let activity = Bitkit.CoreService.shared.activity

    override func setUp() async throws {
        try await super.setUp()
        _ = try initDb(basePath: testDbPath)
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        let dbPath = (testDbPath as NSString).appendingPathComponent("activity.db")
        if FileManager.default.fileExists(atPath: dbPath) {
            try FileManager.default.removeItem(atPath: dbPath)
        }
    }

    private func makeService() -> Bitkit.TransferService {
        Bitkit.TransferService(lightningService: .shared, blocktankService: Bitkit.CoreService.shared.blocktank)
    }

    func testPendingToSpendingActivityDoesNotStoreShortChannelId() async throws {
        var channel = IBtChannel.mock()
        channel.shortChannelId = "820100x5x0"
        let order = IBtOrder.mock(channel: channel)

        await makeService().createPendingToSpendingActivity(order: order, txId: "hwtx1", fee: 141, feeRate: 2)

        let stored = try await activity.getOnchainActivityByTxId(txid: "hwtx1")
        let onchain = try XCTUnwrap(stored)
        XCTAssertNil(onchain.channelId, "The order's short channel id must not be stored as the activity channelId")
        XCTAssertTrue(onchain.isTransfer, "A hardware funding activity must be marked as a transfer")
        XCTAssertEqual(onchain.value, order.feeSat)
    }

    /// The atomic mark-as-transfer must only touch `isTransfer`/`channelId`, preserving confirmation
    /// and fee that a concurrent watcher sync may have written.
    func testMarkOnchainActivityAsTransferPreservesConfirmationAndFee() async throws {
        let seeded = OnchainActivity(
            walletId: WalletScope.default,
            id: "hwtx2",
            txType: .sent,
            txId: "hwtx2",
            value: 1000,
            fee: 500,
            feeRate: 2,
            address: "bc1q...",
            confirmed: true,
            timestamp: 1,
            isBoosted: false,
            boostTxIds: [],
            isTransfer: false,
            doesExist: true,
            confirmTimestamp: 123,
            channelId: nil,
            transferTxId: nil,
            contact: nil,
            createdAt: 1,
            updatedAt: 1,
            seenAt: 1
        )
        try await activity.insert(.onchain(seeded))

        await activity.markOnchainActivityAsTransfer(txId: "hwtx2", channelId: "boltchan")

        let stored = try await activity.getOnchainActivityByTxId(txid: "hwtx2")
        let onchain = try XCTUnwrap(stored)
        XCTAssertTrue(onchain.isTransfer)
        XCTAssertEqual(onchain.channelId, "boltchan")
        XCTAssertTrue(onchain.confirmed, "confirmation must be preserved")
        XCTAssertEqual(onchain.fee, 500, "fee must be preserved")
    }
}
