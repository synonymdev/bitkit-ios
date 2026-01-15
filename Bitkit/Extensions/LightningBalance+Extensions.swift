import Foundation
import LDKNode

/// Extension to provide convenient access to common properties across all LightningBalance cases
extension LightningBalance {
    /// Get the amount in satoshis for any LightningBalance case
    var amountSats: UInt64 {
        switch self {
        case let .claimableOnChannelClose(details):
            return details.amountSatoshis
        case let .claimableAwaitingConfirmations(details):
            return details.amountSatoshis
        case let .contentiousClaimable(details):
            return details.amountSatoshis
        case let .maybeTimeoutClaimableHtlc(details):
            return details.amountSatoshis
        case let .maybePreimageClaimableHtlc(details):
            return details.amountSatoshis
        case let .counterpartyRevokedOutputClaimable(details):
            return details.amountSatoshis
        }
    }

    /// Get a user-friendly description of the balance type
    var balanceUiText: String {
        switch self {
        case .claimableOnChannelClose:
            return "Claimable on Channel Close"
        case let .claimableAwaitingConfirmations(details):
            return "Claimable Awaiting Confirmations (Height: \(details.confirmationHeight))"
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
        case let .claimableAwaitingConfirmations(details):
            return details.confirmationHeight
        case let .contentiousClaimable(details):
            return details.timeoutHeight
        case let .maybeTimeoutClaimableHtlc(details):
            return details.claimableHeight
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
