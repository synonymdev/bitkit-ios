@testable import Bitkit
import BitkitCore
import XCTest

/// Covers the `Activity` walletId helpers that drive the merged activity list + the blue
/// hardware-wallet icon variant.
final class ActivityHardwareTests: XCTestCase {
    private func onchain(
        walletId: String,
        txId: String = "tx1",
        txType: PaymentType = .received,
        doesExist: Bool = true
    ) -> Activity {
        .onchain(OnchainActivity(
            walletId: walletId,
            id: txId,
            txType: txType,
            txId: txId,
            value: 1000,
            fee: 0,
            feeRate: 1,
            address: "",
            confirmed: true,
            timestamp: 1,
            isBoosted: false,
            boostTxIds: [],
            isTransfer: false,
            doesExist: doesExist,
            confirmTimestamp: nil,
            channelId: nil,
            transferTxId: nil,
            contact: nil,
            createdAt: nil,
            updatedAt: nil,
            seenAt: nil
        ))
    }

    private func lightning(walletId: String) -> Activity {
        .lightning(LightningActivity(
            walletId: walletId,
            id: "ln1",
            txType: .received,
            status: .succeeded,
            value: 1000,
            fee: nil,
            invoice: "lnbc1",
            message: "",
            timestamp: 1,
            preimage: nil,
            contact: nil,
            createdAt: nil,
            updatedAt: nil,
            seenAt: nil
        ))
    }

    func testWalletIdExtractedFromBothCases() {
        XCTAssertEqual(onchain(walletId: "trezor:abc").walletId, "trezor:abc")
        XCTAssertEqual(lightning(walletId: WalletScope.default).walletId, WalletScope.default)
    }

    func testIsHardwareWallet() {
        XCTAssertTrue(onchain(walletId: "trezor:abc").isHardwareWallet)
        XCTAssertFalse(onchain(walletId: WalletScope.default).isHardwareWallet)
        XCTAssertFalse(lightning(walletId: WalletScope.default).isHardwareWallet)
    }

    /// A hardware transfer's funding tx is now stored only under the hardware wallet id, so the
    /// merged list no longer collapses same-txid rows: activity identity is (walletId, activityId).
    /// Replacement filtering therefore has to be evaluated against each row's *own* wallet — a boost
    /// chain never crosses wallets, so the normal wallet's replaced-txid set says nothing about a
    /// hardware row that happens to share a txid.
    func testReplacementFilteringIsScopedToTheRowsOwnWallet() {
        let main = onchain(walletId: WalletScope.default, txId: "tx1", txType: .sent, doesExist: false)
        let hardware = onchain(walletId: "trezor:abc", txId: "tx1", txType: .sent, doesExist: false)

        // As `ActivityListViewModel.filterOutReplacedSentTransactions` does it: each row checked
        // against the boost set of the wallet that owns it.
        let boostTxIdsByWallet: [String: Set<String>] = [WalletScope.default: ["tx1"], "trezor:abc": []]

        XCTAssertTrue(main.isReplacedSentTransaction(txIdsInBoostTxIds: boostTxIdsByWallet[main.walletId] ?? []))
        XCTAssertFalse(
            hardware.isReplacedSentTransaction(txIdsInBoostTxIds: boostTxIdsByWallet[hardware.walletId] ?? []),
            "the hardware row survives: it was not replaced in its own wallet"
        )

        // Using one global set — the pre-PR behaviour — would wrongly drop the hardware row too.
        XCTAssertTrue(hardware.isReplacedSentTransaction(txIdsInBoostTxIds: ["tx1"]))
    }
}
