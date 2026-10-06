@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class RbfActivityFeeRateTests: XCTestCase {
    private let testDbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("RbfActivityFeeRateTests-\(UUID().uuidString)", isDirectory: true)
    private let activity = Bitkit.CoreService.shared.activity
    private let originalTxid = String(repeating: "1", count: 64)
    private let replacementTxid = String(repeating: "2", count: 64)
    private let timestamp = UInt64(Date().timeIntervalSince1970) + 100

    override func setUp() async throws {
        try await super.setUp()
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(at: testDbPath, withIntermediateDirectories: true)
        _ = try initDb(basePath: testDbPath.path)
        try await activity.insert(.onchain(onchain(txid: originalTxid)))
    }

    override func tearDown() async throws {
        await drainCoreServiceQueue()
        await repointCoreToAppStorage()
        try FileManager.default.removeItem(at: testDbPath)
        try await super.tearDown()
    }

    func testBoostBeforeReplacementArrivesPersistsRateThroughSyncAndConfirmation() async throws {
        let service = makeService()
        _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)

        let pending = try await service.getPreActivityMetadata(searchKey: replacementTxid)
        XCTAssertEqual(pending?.feeRate, 25, "The fee rate must be keyed by the replacement txid, not just stored on the original")
        XCTAssertEqual(pending?.txId, replacementTxid)

        try await service.syncLdkNodePayments([payment(txid: replacementTxid)])
        try await assertReplacement(service, rate: 25)
        let consumed = try await service.getPreActivityMetadata(searchKey: replacementTxid)
        XCTAssertNil(consumed, "Core should consume the pending fee metadata when it creates the replacement")

        let newService = makeService()
        try await newService.syncLdkNodePayments([payment(txid: replacementTxid, confirmed: true)])
        try await assertReplacement(newService, rate: 25)
        let stored = try await newService.getOnchainActivityByTxId(txid: replacementTxid)
        XCTAssertEqual(stored?.confirmed, true)
    }

    func testReplacementArrivingBeforeBoostReturnsIsCorrectedWithoutLosingMetadata() async throws {
        let service = makeService { _, _ in
            var replacement = self.onchain(txid: self.replacementTxid, fee: 2500)
            replacement.id = "replacement-payment-id"
            replacement.contact = "saved-contact"
            replacement.seenAt = self.timestamp
            replacement.isBoosted = true
            replacement.boostTxIds = [self.originalTxid]
            try await self.activity.insert(.onchain(replacement))
            await self.activity.markActivityAsSeen(id: replacement.id, seenAt: self.timestamp)
            try await self.activity.appendTags(toActivity: replacement.id, ["saved-tag"])
            return self.replacementTxid
        }

        _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)
        try await assertReplacement(service, rate: 25)
        let stored = try await service.getOnchainActivityByTxId(txid: replacementTxid)
        let replacement = try XCTUnwrap(stored)
        XCTAssertEqual(replacement.id, "replacement-payment-id")
        XCTAssertEqual(replacement.contact, "saved-contact")
        XCTAssertEqual(replacement.seenAt, timestamp)
        XCTAssertEqual(replacement.boostTxIds, [originalTxid])
        let tags = try await service.tags(forActivity: replacement.id)
        XCTAssertEqual(tags, ["saved-tag"])
    }

    func testReplacementEventBeforeBoostReturnsDoesNotResurrectOriginal() async throws {
        let service = makeService { _, _ in
            try await self.activity.insert(.onchain(self.onchain(txid: self.replacementTxid, fee: 2500)))
            try await self.activity.handleOnchainTransactionReplaced(txid: self.originalTxid, conflicts: [self.replacementTxid])
            return self.replacementTxid
        }

        _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)
        try await assertReplacement(service, rate: 25)
        let original = try await service.getOnchainActivityByTxId(txid: originalTxid)
        XCTAssertEqual(original?.doesExist, false)
        XCTAssertEqual(original?.isBoosted, false)
    }

    func testPendingReplacementMetadataKeepsExistingTags() async throws {
        let service = makeService()
        let metadata = PreActivityMetadata(
            walletId: Bitkit.WalletScope.default, paymentId: replacementTxid, tags: ["pending-tag"], paymentHash: nil,
            txId: replacementTxid, address: "bcrt1qrecipient", isReceive: false, feeRate: 1,
            isTransfer: false, channelId: nil, createdAt: timestamp
        )
        try await service.addPreActivityMetadata(metadata)
        _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)
        try await service.syncLdkNodePayments([payment(txid: replacementTxid)])

        try await assertReplacement(service, rate: 25)
        let stored = try await service.getOnchainActivityByTxId(txid: replacementTxid)
        let replacement = try XCTUnwrap(stored)
        let tags = try await service.tags(forActivity: replacement.id)
        XCTAssertEqual(tags, ["pending-tag"])
    }

    func testRepeatedBoostRecordsEachReplacementRateSeparately() async throws {
        let nextTxid = String(repeating: "3", count: 64)
        let service = makeService { txid, _ in txid == self.originalTxid ? self.replacementTxid : nextTxid }
        _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)
        try await service.syncLdkNodePayments([payment(txid: replacementTxid)])
        let stored = try await service.getOnchainActivityByTxId(txid: replacementTxid)
        let replacement = try XCTUnwrap(stored)

        _ = try await service.boostOnchainTransaction(activityId: replacement.id, feeRate: 40)
        try await service.syncLdkNodePayments([payment(txid: nextTxid, fee: 4000)])
        let next = try await service.getOnchainActivityByTxId(txid: nextTxid)
        XCTAssertEqual(next?.feeRate, 40)
        XCTAssertEqual(next?.fee, 4000)
    }

    func testFailedBoostDoesNotRecordReplacementMetadata() async throws {
        let service = makeService { _, _ in throw TestError.bumpFailed }
        do {
            _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)
            XCTFail("Expected a failed boost")
        } catch {
            let wrapped = try XCTUnwrap(error as? Bitkit.AppError)
            XCTAssertTrue(wrapped.underlyingError is TestError)
        }
        let metadata = try await service.getPreActivityMetadata(searchKey: replacementTxid)
        XCTAssertNil(metadata)
        let original = try await service.getOnchainActivityByTxId(txid: originalTxid)
        XCTAssertEqual(original?.feeRate, 1)
        XCTAssertEqual(original?.isBoosted, false)
    }

    func testStaleEventSnapshotCannotOverwriteCorrectedRate() async throws {
        let service = makeService()
        let stale = onchain(txid: replacementTxid, fee: 2500)
        try await service.insert(.onchain(stale))
        _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)

        try await service.upsertOnchainActivityPreservingFeeRate(stale)
        try await assertReplacement(service, rate: 25)
    }

    func testSameTxidInHardwareWalletIsNotModifiedByNativeBoost() async throws {
        let service = makeService()
        var hardware = onchain(txid: replacementTxid, fee: 2500)
        hardware.walletId = "trezor:test"
        hardware.feeRate = 7
        try await service.insert(.onchain(hardware))
        _ = try await service.boostOnchainTransaction(activityId: originalTxid, feeRate: 25)
        try await service.syncLdkNodePayments([payment(txid: replacementTxid)])
        try await assertReplacement(service, rate: 25)

        let stored = try await service.getOnchainActivityByTxId(txid: replacementTxid, walletId: hardware.walletId)
        XCTAssertEqual(stored?.feeRate, 7)
    }

    private func makeService(
        bump: ((String, UInt32) async throws -> String)? = nil
    ) -> Bitkit.ActivityService {
        Bitkit.ActivityService(coreService: .shared, bumpFeeByRbf: bump ?? { _, _ in self.replacementTxid })
    }

    private func assertReplacement(_ service: Bitkit.ActivityService, rate: UInt64) async throws {
        let stored = try await service.getOnchainActivityByTxId(txid: replacementTxid)
        let replacement = try XCTUnwrap(stored)
        XCTAssertEqual(replacement.feeRate, rate)
        XCTAssertEqual(replacement.fee, 2500, "The replacement's real total fee must not be copied from its parent")
        XCTAssertEqual(
            TransactionSpeed.feeTierKeyComponent(for: replacement.feeRate, feeEstimates: FeeRates(fast: 20, mid: 10, slow: 5)),
            "fast"
        )
    }

    private func payment(txid: String, fee: UInt64 = 2500, confirmed: Bool = false) -> PaymentDetails {
        PaymentDetails(
            id: "payment-\(txid)",
            kind: .onchain(
                txid: txid,
                status: confirmed ? .confirmed(blockHash: String(repeating: "0", count: 64), height: 100, timestamp: timestamp) : .unconfirmed
            ),
            amountMsat: 10000 * 1000, feePaidMsat: fee * 1000, direction: .outbound, status: .pending,
            latestUpdateTimestamp: timestamp + (confirmed ? 100 : 0)
        )
    }

    private func onchain(txid: String, fee: UInt64 = 100) -> OnchainActivity {
        OnchainActivity(
            walletId: Bitkit.WalletScope.default, id: txid, txType: .sent, txId: txid, value: 10000, fee: fee, feeRate: 1,
            address: "bcrt1qrecipient", confirmed: false, timestamp: timestamp, isBoosted: false, boostTxIds: [],
            isTransfer: false, doesExist: true, confirmTimestamp: nil, channelId: nil, transferTxId: nil, contact: nil,
            createdAt: timestamp, updatedAt: timestamp, seenAt: nil
        )
    }

    private enum TestError: Error {
        case bumpFailed
    }
}
