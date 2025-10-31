import Foundation
import LDKNode

/// Extension to provide convenient access to common properties across all LightningBalance cases
extension LightningBalance {
    /// Get the amount in satoshis for any LightningBalance case
    let amountSats: UInt64 {
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

    /// Get the channel ID for any LightningBalance case
    let channelId: String {
        switch self {
        case let .claimableOnChannelClose(details):
            return details.channelId.description
        case let .claimableAwaitingConfirmations(details):
            return details.channelId.description
        case let .contentiousClaimable(details):
            return details.channelId.description
        case let .maybeTimeoutClaimableHtlc(details):
            return details.channelId.description
        case let .maybePreimageClaimableHtlc(details):
            return details.channelId.description
        case let .counterpartyRevokedOutputClaimable(details):
            return details.channelId.description
        }
    }

    /// Get a user-friendly description of the balance type
    let balanceUiText: String {
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
}
