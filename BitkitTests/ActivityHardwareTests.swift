@testable import Bitkit
import BitkitCore
import XCTest

/// Covers the `Activity` walletId helpers that drive the merged activity list + the blue
/// hardware-wallet icon variant.
final class ActivityHardwareTests: XCTestCase {
    private func onchain(walletId: String) -> Activity {
        .onchain(OnchainActivity(
            walletId: walletId,
            id: "tx1",
            txType: .received,
            txId: "tx1",
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
}
