@testable import Bitkit
import BitkitCore
import XCTest

/// Covers the `Activity` walletId helpers that drive the merged activity list + the blue
/// hardware-wallet icon variant.
final class ActivityHardwareTests: XCTestCase {
    private func onchain(walletId: String, txId: String = "tx1") -> Activity {
        .onchain(OnchainActivity(
            walletId: walletId,
            id: txId,
            txType: .received,
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
            doesExist: true,
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

    func testWithoutHardwareDuplicatesCollapsesSharedTx() {
        let mainTransfer = onchain(walletId: WalletScope.default, txId: "tx1")
        let hwDuplicate = onchain(walletId: "trezor:abc", txId: "tx1")
        let hwOnly = onchain(walletId: "trezor:abc", txId: "tx2")
        let ln = lightning(walletId: WalletScope.default)

        let result = [mainTransfer, hwDuplicate, hwOnly, ln].withoutHardwareDuplicates()

        func txIds(hardware: Bool) -> [String] {
            result.compactMap { activity in
                guard activity.isHardwareWallet == hardware, case let .onchain(onchain) = activity else { return nil }
                return onchain.txId
            }
        }

        XCTAssertEqual(result.count, 3, "the hardware duplicate of tx1 is dropped")
        XCTAssertEqual(txIds(hardware: false), ["tx1"], "the main-wallet transfer row is kept")
        XCTAssertEqual(txIds(hardware: true), ["tx2"], "hardware-only tx2 is kept, tx1 duplicate removed")
        XCTAssertTrue(result.contains { if case .lightning = $0 { return true }; return false }, "lightning rows are untouched")
    }
}
