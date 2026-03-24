import Foundation
import LDKNode

/// Extension to provide convenient access to common properties across all LightningBalance cases
extension LightningBalance {
    /// Get the amount in satoshis for any LightningBalance case
    var amountSats: UInt64 {
        switch self {
        case let .claimableOnChannelClose(_, _, amount, _, _, _, _, _):
            return amount
        case let .claimableAwaitingConfirmations(_, _, amount, _, _):
            return amount
        case let .contentiousClaimable(_, _, amount, _, _, _):
            return amount
        case let .maybeTimeoutClaimableHtlc(_, _, amount, _, _, _):
            return amount
        case let .maybePreimageClaimableHtlc(_, _, amount, _, _):
            return amount
        case let .counterpartyRevokedOutputClaimable(_, _, amount):
            return amount
        }
    }

    /// Get a user-friendly description of the balance type
    var balanceUiText: String {
        switch self {
        case .claimableOnChannelClose:
            return "Claimable on Channel Close"
        case let .claimableAwaitingConfirmations(_, _, _, confirmationHeight, _):
            return "Claimable Awaiting Confirmations (Height: \(confirmationHeight))"
        case .contentiousClaimable:
            return "Contentious Claimable"
        case .maybeTimeoutClaimableHtlc:
            return "Maybe Timeout Claimable HTLC"
        case .maybePreimageClaimableHtlc:
            return "Maybe Preimage Claimable HTLC"
        case .counterpartyRevokedOutputClaimable:
            return "Counterparty Revoked Output Claimable"
        }
    }

    /// Get the block height at which funds become claimable (for timelocked balances)
    var claimableAtHeight: UInt32? {
        switch self {
        case let .claimableAwaitingConfirmations(_, _, _, confirmationHeight, _):
            return confirmationHeight
        case let .contentiousClaimable(_, _, _, timeoutHeight, _, _):
            return timeoutHeight
        case let .maybeTimeoutClaimableHtlc(_, _, _, claimableHeight, _, _):
            return claimableHeight
        default:
            return nil
        }
    }

    /// Whether this balance is timelocked (force close scenario)
    var isTimelocked: Bool {
        switch self {
        case .contentiousClaimable, .claimableAwaitingConfirmations:
            return true
        default:
            return false
        }
    }
}
