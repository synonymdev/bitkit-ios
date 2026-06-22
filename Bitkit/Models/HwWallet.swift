import BitkitCore
import Foundation

/// A paired hardware wallet tracked as a watch-only balance.
struct HwWallet: Identifiable {
    let id: String
    let name: String
    let model: String?
    let isConnected: Bool
    let balanceSats: UInt64
    let activities: [Activity]
    let deviceIds: Set<String>

    init(
        id: String,
        name: String,
        model: String?,
        isConnected: Bool,
        balanceSats: UInt64,
        activities: [Activity],
        deviceIds: Set<String>? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.isConnected = isConnected
        self.balanceSats = balanceSats
        self.activities = activities
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
