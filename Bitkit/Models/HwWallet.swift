import BitkitCore
import Foundation

/// A paired hardware wallet tracked as a watch-only balance. One per wallet identity: a Trezor with
/// passphrase protection contributes its standard wallet plus one of these per hidden wallet.
///
/// Activities are NOT held here — they are persisted in bitkit-core scoped by `walletId`
/// and read back through the normal activity pipeline (see `HwWalletManager`).
struct HwWallet: Identifiable {
    /// The wallet identity, equal to `walletId`. Routes and every wallet-scoped API key off it,
    /// since the transport-level device id is shared by all of a device's wallets.
    let id: String
    /// bitkit-core wallet id scoping this wallet's activities (see `HwWalletId`).
    let walletId: String
    let name: String
    let model: String?
    let isConnected: Bool
    let balanceSats: UInt64
    /// Balance available to fund a transfer to spending, sourced from the native-segwit account only
    /// (v1 funds from native-segwit; other address types are watched but not spent). Defaults to
    /// `balanceSats` when not computed separately.
    let fundingBalanceSats: UInt64
    /// Transport-level ids this wallet is reachable over. Bluetooth-only on iOS, so effectively one.
    let deviceIds: Set<String>
    /// Whether reaching this wallet needs a passphrase, i.e. it is a hidden wallet.
    let passphraseProtected: Bool

    init(
        id: String,
        walletId: String,
        name: String,
        model: String?,
        isConnected: Bool,
        balanceSats: UInt64,
        fundingBalanceSats: UInt64? = nil,
        deviceIds: Set<String>? = nil,
        passphraseProtected: Bool = false
    ) {
        self.id = id
        self.walletId = walletId
        self.name = name
        self.model = model
        self.isConnected = isConnected
        self.balanceSats = balanceSats
        self.fundingBalanceSats = fundingBalanceSats ?? balanceSats
        self.deviceIds = deviceIds ?? [id]
        self.passphraseProtected = passphraseProtected
    }
}

/// Per-device balance snapshot folded into the headline total via `BalanceState`.
struct HwWalletBalance: Codable, Equatable, Identifiable {
    let id: String
    let sats: UInt64
}

/// A device group's wallet-scoped watcher snapshot, ready to hand to bitkit-core.
struct HwWalletSnapshot: Equatable {
    let walletId: String
    let activities: [Activity]
    let transactionDetails: [TransactionDetails]
    /// True when every watcher the current device/settings snapshot wants for this wallet has
    /// reported at least once, so these rows cover the whole wallet. Only a complete snapshot may
    /// prune stored rows it does not mention — see `HwSnapshotMerge.plan(pruneMissing:)`.
    let isComplete: Bool
}

/// A newly detected inbound transaction to a watched hardware wallet.
struct HwWalletReceivedTx: Equatable {
    let txid: String
    let sats: UInt64
}

/// The next unused external address for a paired hardware-wallet account.
struct HwReceiveAddress: Equatable {
    let address: String
    let path: String
    let addressType: AddressScriptType
}

extension HwWallet {
    var toBalance: HwWalletBalance {
        HwWalletBalance(id: id, sats: balanceSats)
    }
}
