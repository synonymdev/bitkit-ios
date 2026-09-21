@testable import Bitkit
import BitkitCore
import XCTest

/// Covers how tags on watch-only hardware activities are shaped for the METADATA backup, since
/// they cannot ride the ACTIVITY backup — see `HwActivityTagBackup`.
final class HwActivityTagBackupTests: XCTestCase {
    private let walletId = "trezor:abc"
    private let otherWalletId = "trezor:def"

    private func onchain(
        id: String = "hw-activity",
        walletId: String? = nil,
        txType: PaymentType = .received,
        txId: String = "hw-txid",
        address: String = "bcrt1qhw",
        timestamp: UInt64 = 123,
        feeRate: UInt64 = 1,
        isTransfer: Bool = false,
        channelId: String? = nil
    ) -> OnchainActivity {
        OnchainActivity(
            walletId: walletId ?? self.walletId,
            id: id,
            txType: txType,
            txId: txId,
            value: 1000,
            fee: 1,
            feeRate: feeRate,
            address: address,
            confirmed: true,
            timestamp: timestamp,
            isBoosted: false,
            boostTxIds: [],
            isTransfer: isTransfer,
            doesExist: true,
            confirmTimestamp: nil,
            channelId: channelId,
            transferTxId: nil,
            contact: nil,
            createdAt: nil,
            updatedAt: nil,
            seenAt: nil
        )
    }

    private func metadata(walletId: String, paymentId: String, tags: [String] = ["cold"]) -> PreActivityMetadata {
        PreActivityMetadata(
            walletId: walletId,
            paymentId: paymentId,
            tags: tags,
            paymentHash: nil,
            txId: nil,
            address: nil,
            isReceive: false,
            feeRate: 0,
            isTransfer: false,
            channelId: nil,
            createdAt: 0
        )
    }

    // MARK: - Lookup key

    func testReceivedActivityIsKeyedByAddress() {
        let activity = onchain(txType: .received)
        let tags = [ActivityTags(walletId: walletId, activityId: activity.id, tags: ["cold"])]

        let record = HwActivityTagBackup.preActivityMetadata(activities: [activity], tags: tags).first

        XCTAssertEqual(record?.walletId, walletId)
        XCTAssertEqual(record?.paymentId, activity.id)
        XCTAssertEqual(record?.address, "bcrt1qhw")
        XCTAssertEqual(record?.txId, "hw-txid")
        XCTAssertEqual(record?.isReceive, true)
        XCTAssertEqual(record?.tags, ["cold"])
    }

    func testSentActivityIsKeyedByPaymentId() {
        let activity = onchain(txType: .sent)
        let tags = [ActivityTags(walletId: walletId, activityId: activity.id, tags: ["cold"])]

        let record = HwActivityTagBackup.preActivityMetadata(activities: [activity], tags: tags).first

        XCTAssertEqual(record?.paymentId, "hw-txid")
        XCTAssertNil(record?.address)
        XCTAssertEqual(record?.isReceive, false)
    }

    /// Core copies these onto the activity it attaches to, and only when they are set, so a
    /// tag-only record carrying them would overwrite what the watcher reported.
    func testCopiedFieldsAreLeftNeutral() {
        let activity = onchain(feeRate: 25, isTransfer: true, channelId: "chan")
        let tags = [ActivityTags(walletId: walletId, activityId: activity.id, tags: ["cold"])]

        let record = HwActivityTagBackup.preActivityMetadata(activities: [activity], tags: tags).first

        XCTAssertEqual(record?.feeRate, 0)
        XCTAssertEqual(record?.isTransfer, false)
        XCTAssertNil(record?.channelId)
        XCTAssertNil(record?.paymentHash)
    }

    func testTimestampIsConvertedToMillis() {
        let activity = onchain(timestamp: 123)
        let tags = [ActivityTags(walletId: walletId, activityId: activity.id, tags: ["cold"])]

        let record = HwActivityTagBackup.preActivityMetadata(activities: [activity], tags: tags).first

        XCTAssertEqual(record?.createdAt, 123_000)
    }

    // MARK: - Selection

    func testDefaultWalletTagsAreExcluded() {
        let activity = onchain(walletId: WalletScope.default)
        let tags = [ActivityTags(walletId: WalletScope.default, activityId: activity.id, tags: ["daily"])]

        let records = HwActivityTagBackup.preActivityMetadata(activities: [activity], tags: tags)

        XCTAssertTrue(records.isEmpty)
    }

    func testEmptyTagListIsExcluded() {
        let activity = onchain()
        let tags = [ActivityTags(walletId: walletId, activityId: activity.id, tags: [])]

        let records = HwActivityTagBackup.preActivityMetadata(activities: [activity], tags: tags)

        XCTAssertTrue(records.isEmpty)
    }

    func testTagWithoutMatchingActivityIsSkipped() {
        let tags = [ActivityTags(walletId: walletId, activityId: "gone", tags: ["cold"])]

        let records = HwActivityTagBackup.preActivityMetadata(activities: [onchain()], tags: tags)

        XCTAssertTrue(records.isEmpty)
    }

    func testUntaggedActivityIsSkipped() {
        let records = HwActivityTagBackup.preActivityMetadata(activities: [onchain()], tags: [])

        XCTAssertTrue(records.isEmpty)
    }

    /// Activity ids are unique only within a wallet scope, so two paired devices that saw the same
    /// transaction must not inherit each other's tags.
    func testTagsDoNotCrossWalletScopes() {
        let tagged = onchain(id: "shared-id", walletId: walletId)
        let untagged = onchain(id: "shared-id", walletId: otherWalletId)
        let tags = [ActivityTags(walletId: walletId, activityId: "shared-id", tags: ["cold"])]

        let records = HwActivityTagBackup.preActivityMetadata(activities: [tagged, untagged], tags: tags)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.walletId, walletId)
    }

    // MARK: - Deduplication

    func testDeduplicationKeepsFirstPerKey() {
        let first = metadata(walletId: walletId, paymentId: "p1", tags: ["live"])
        let second = metadata(walletId: walletId, paymentId: "p1", tags: ["stale"])

        let records = HwActivityTagBackup.deduplicated([first, second])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.tags, ["live"])
    }

    func testDeduplicationIsScopedPerWallet() {
        let mine = metadata(walletId: walletId, paymentId: "p1")
        let theirs = metadata(walletId: otherWalletId, paymentId: "p1")

        let records = HwActivityTagBackup.deduplicated([mine, theirs])

        XCTAssertEqual(records.count, 2)
    }

    func testDeduplicationPreservesOrder() {
        let a = metadata(walletId: walletId, paymentId: "a")
        let b = metadata(walletId: walletId, paymentId: "b")
        let c = metadata(walletId: walletId, paymentId: "c")

        let records = HwActivityTagBackup.deduplicated([a, b, a, c])

        XCTAssertEqual(records.map(\.paymentId), ["a", "b", "c"])
    }
}
