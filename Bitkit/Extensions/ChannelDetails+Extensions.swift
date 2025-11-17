import BitkitCore
import Foundation
import LDKNode

extension ChannelDetails {
    /// Returns the spendable balance in satoshis (outbound capacity + punishment reserve)
    var spendableBalanceSats: UInt64 {
        return outboundCapacityMsat / 1000 + (unspendablePunishmentReserve ?? 0)
    }

    /// Find the linked Blocktank order for this channel
    /// - Parameter orders: Array of Blocktank orders to search
    /// - Returns: The matching order if found, nil otherwise
    func findLinkedOrder(in orders: [IBtOrder]) -> IBtOrder? {
        // Match by userChannelId (which is set to order.id for Blocktank orders)
        if let order = orders.first(where: { $0.id == userChannelId }) {
            return order
        }

        // Match by short channel ID
        if let shortChannelId {
            let shortChannelIdString = String(shortChannelId)
            if let order = orders.first(where: { order in
                order.channel?.shortChannelId == shortChannelIdString
            }) {
                return order
            }
        }

        // Match by funding transaction
        if let fundingTxo {
            if let order = orders.first(where: { order in
                order.channel?.fundingTx.id == fundingTxo.txid
            }) {
                return order
            }
        }

        // Match by counterparty node ID (less reliable, could match multiple)
        let counterpartyNodeIdString = counterpartyNodeId.description
        if let order = orders.first(where: { order in
            guard let orderChannel = order.channel else { return false }
            return orderChannel.clientNodePubkey == counterpartyNodeIdString ||
                orderChannel.lspNodePubkey == counterpartyNodeIdString
        }) {
            return order
        }

        return nil
    }
}

// MARK: - Mock Data

extension ChannelDetails {
    static func mock(
        isChannelReady: Bool = true,
        isUsable: Bool = true,
        isAnnounced: Bool = false,
        channelValueSats: UInt64 = 100_000,
        outboundCapacityMsat: UInt64 = 50_000_000, // 50,000 sats in msat
        inboundCapacityMsat: UInt64 = 50_000_000, // 50,000 sats in msat
        shortChannelId: UInt64? = 123_456_789
    ) -> ChannelDetails {
        return ChannelDetails(
            channelId: "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            counterpartyNodeId: "03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad",
            fundingTxo: OutPoint(
                txid: "abcd1234567890abcd1234567890abcd1234567890abcd1234567890abcd1234",
                vout: 0
            ),
            shortChannelId: shortChannelId,
            outboundScidAlias: nil,
            inboundScidAlias: nil,
            channelValueSats: channelValueSats,
            unspendablePunishmentReserve: 1000,
            userChannelId: "123abc",
            feerateSatPer1000Weight: 2500,
            outboundCapacityMsat: outboundCapacityMsat,
            inboundCapacityMsat: inboundCapacityMsat,
            confirmationsRequired: isChannelReady ? 3 : nil,
            confirmations: isChannelReady ? 3 : 1,
            isOutbound: true,
            isChannelReady: isChannelReady,
            isUsable: isUsable,
            isAnnounced: isAnnounced,
            cltvExpiryDelta: 144,
            counterpartyUnspendablePunishmentReserve: 1000,
            counterpartyOutboundHtlcMinimumMsat: 1000,
            counterpartyOutboundHtlcMaximumMsat: 99_000_000,
            counterpartyForwardingInfoFeeBaseMsat: 1000,
            counterpartyForwardingInfoFeeProportionalMillionths: 100,
            counterpartyForwardingInfoCltvExpiryDelta: 144,
            nextOutboundHtlcLimitMsat: outboundCapacityMsat,
            nextOutboundHtlcMinimumMsat: 1000,
            forceCloseSpendDelay: nil,
            inboundHtlcMinimumMsat: 1000,
            inboundHtlcMaximumMsat: inboundCapacityMsat > 0 ? inboundCapacityMsat : nil,
            config: .init(
                forwardingFeeProportionalMillionths: 0,
                forwardingFeeBaseMsat: 0,
                cltvExpiryDelta: 0,
                maxDustHtlcExposure: .feeRateMultiplier(multiplier: 0),
                forceCloseAvoidanceMaxFeeSatoshis: 0,
                acceptUnderpayingHtlcs: true
            )
        )
    }
}
