import Foundation

/// Confirm total for the spending transfer screen: the amount of bitcoin that leaves the wallet.
enum SpendingConfirmTotal {
    /// When send-all funds the order, the sweep spends `maxSendable + networkFee` (the spendable balance).
    /// Otherwise the total is the order fee plus the miner fee.
    static func leavingAmount(
        orderFeeSat: UInt64,
        networkFeeSat: UInt64,
        shouldUseSendAll: Bool,
        maxSendable: UInt64?
    ) -> UInt64 {
        if shouldUseSendAll, let maxSendable {
            return maxSendable.saturatingAdd(networkFeeSat)
        }
        return orderFeeSat.saturatingAdd(networkFeeSat)
    }
}

/// The network fee and total the spending confirm screen shows.
struct SpendingConfirmAmounts: Equatable {
    let networkFeeSat: UInt64
    let totalSat: UInt64
}

enum SpendingFeeIncrease: Equatable {
    case service(amountSat: UInt64)
    case network(amountSat: UInt64)

    /// The localized toast description for this increase, with `amount` already formatted in the user's primary display unit.
    func toastDescription(formattingAmount format: (UInt64) -> String) -> String {
        switch self {
        case let .service(amountSat):
            t("lightning__spending_confirm__fees_changed_service", variables: ["amount": format(amountSat)])
        case let .network(amountSat):
            t("lightning__spending_confirm__fees_changed_network", variables: ["amount": format(amountSat)])
        }
    }
}

struct SpendingFeesIncreasedError: Error {}
