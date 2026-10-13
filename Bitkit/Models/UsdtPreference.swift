import BitkitCore
import Foundation

enum UsdtPreference: String {
    case undecided
    case disabled
    case enabled

    static let key = "usdtPreference"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key) == enabled.rawValue
    }

    static func protectsFunds(balance: UInt64?, transfers: [UsdtTransfer]) -> Bool {
        (balance ?? 0) > 0 || (balance == nil && !transfers.isEmpty) || transfers.contains { transfer in
            switch transfer.status {
            case .pending, .bridging, .bridgeNeedsAttention, .bridgeFailed: true
            case .confirmed, .failed, .replaced, .bridgeRefunded: false
            }
        }
    }

    static func hasPendingDeposit(_ status: String) -> Bool {
        !["completed", "refunded", "waiting", "awaiting_deposit", "expired"].contains(status)
    }
}
