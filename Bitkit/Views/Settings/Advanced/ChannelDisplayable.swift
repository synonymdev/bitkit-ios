import BitkitCore
import Foundation
import LDKNode

/// Protocol to unify ChannelDetails and ClosedChannelDetails for display purposes
protocol ChannelDisplayable {
    var channelValueSats: UInt64 { get }
    var outboundCapacityMsat: UInt64 { get }
    var inboundCapacityMsat: UInt64 { get }
    var displayedUnspendablePunishmentReserve: UInt64 { get }
    var balanceOnCloseSats: UInt64 { get }
    var forwardingFeeBaseMsat: UInt32 { get }
    var forwardingFeeProportionalMillionths: UInt32 { get }
    var channelIdString: String { get }
    var counterpartyNodeIdString: String { get }
    var displayedFundingTxoTxid: String? { get }
    var fundingTxoVout: UInt32? { get }
    var isChannelReady: Bool { get }
    var isUsable: Bool { get }
    var isClosed: Bool { get }
    var displayedClosedAt: UInt64? { get }
    var closureReason: String? { get }
}

extension ChannelDetails: ChannelDisplayable {
    var channelIdString: String {
        channelId.description
    }

    var counterpartyNodeIdString: String {
        counterpartyNodeId.description
    }

    var displayedFundingTxoTxid: String? {
        fundingTxo?.txid.description
    }

    var fundingTxoVout: UInt32? {
        fundingTxo?.vout
    }

    var forwardingFeeBaseMsat: UInt32 {
        config.forwardingFeeBaseMsat
    }

    var forwardingFeeProportionalMillionths: UInt32 {
        config.forwardingFeeProportionalMillionths
    }

    var displayedUnspendablePunishmentReserve: UInt64 {
        unspendablePunishmentReserve ?? 0
    }

    var isClosed: Bool {
        false
    }

    var displayedClosedAt: UInt64? {
        nil
    }

    var closureReason: String? {
        nil
    }
}

extension ClosedChannelDetails: ChannelDisplayable {
    var channelIdString: String {
        channelId
    }

    var counterpartyNodeIdString: String {
        counterpartyNodeId
    }

    var displayedFundingTxoTxid: String? {
        fundingTxoTxid
    }

    var fundingTxoVout: UInt32? {
        fundingTxoIndex
    }

    var displayedUnspendablePunishmentReserve: UInt64 {
        unspendablePunishmentReserve
    }

    var balanceOnCloseSats: UInt64 {
        outboundCapacityMsat / 1000 + unspendablePunishmentReserve
    }

    var isChannelReady: Bool {
        false
    }

    var isUsable: Bool {
        false
    }

    var isClosed: Bool {
        true
    }

    var displayedClosedAt: UInt64? {
        closedAt
    }

    var closureReason: String? {
        channelClosureReason.isEmpty ? nil : channelClosureReason
    }
}
