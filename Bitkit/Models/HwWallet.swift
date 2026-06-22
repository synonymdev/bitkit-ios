import BitkitCore
import Foundation

/// A paired hardware wallet tracked as a watch-only balance.
///
/// Activities are NOT held here — they are persisted in bitkit-core scoped by `walletId`
/// and read back through the normal activity pipeline (see `HwWalletManager`).
struct HwWallet: Identifiable {
    let id: String
    /// bitkit-core wallet id scoping this device's activities (see `HwWalletId`).
    let walletId: String
    let name: String
    let model: String?
    let isConnected: Bool
    let balanceSats: UInt64
    let deviceIds: Set<String>

    init(
        id: String,
        walletId: String,
        name: String,
        model: String?,
        isConnected: Bool,
        balanceSats: UInt64,
        deviceIds: Set<String>? = nil
    ) {
        self.id = id
        self.walletId = walletId
        self.name = name
        self.model = model
        self.isConnected = isConnected
        self.balanceSats = balanceSats
        self.deviceIds = deviceIds ?? [id]
    }
}

/// Per-device balance snapshot folded into the headline total via `BalanceState`.
struct HwWalletBalance: Codable, Equatable, Identifiable {
    let id: String
    let sats: UInt64
}

/// A newly detected inbound transaction to a watched hardware wallet.
struct HwWalletReceivedTx: Equatable {
    let txid: String
    let sats: UInt64
}

extension HwWallet {
    var toBalance: HwWalletBalance {
        HwWalletBalance(id: id, sats: balanceSats)
    }
}
