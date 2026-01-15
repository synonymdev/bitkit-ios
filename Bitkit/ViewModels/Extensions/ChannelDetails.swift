import LDKNode

extension ChannelDetails {
    /// Calculates our total balance in the channel (see `value_to_self_msat` in rust-lightning).
    ///
    /// This represents the amount we would receive if the channel closes now (excluding fees).
    /// Approximates ldk-node's `ClaimableOnChannelClose.amountSatoshis` (excluding HTLCs).
    ///
    /// Formula: outbound_capacity + our_reserve
    /// - outbound_capacity: What we can spend now over Lightning
    /// - our_reserve: Our reserve that we get back on close
    var amountOnClose: UInt64 {
        let outboundCapacitySat = outboundCapacityMsat / 1000
        let ourReserve = unspendablePunishmentReserve ?? 0

        return outboundCapacitySat + ourReserve
    }
}
