import LDKNode

extension ChannelDetails {
    /// Calculates our total balance in the channel (see `value_to_self_msat` in rust-lightning).
    ///
    /// This represents the amount we would receive if the channel closes now (excluding fees).
    /// Matches ldk-node's `ClaimableOnChannelClose.amountSatoshis` (excluding HTLCs).
    ///
    /// Formula: outbound_capacity + counterparty_reserve
    /// - outbound_capacity: What we can spend now over Lightning
    /// - counterparty_reserve: Their reserve that comes back to us on close
    var amountOnClose: UInt64 {
        let outboundCapacitySat = outboundCapacityMsat / 1000
        let counterpartyReserve = counterpartyUnspendablePunishmentReserve

        return outboundCapacitySat + counterpartyReserve
    }
}
