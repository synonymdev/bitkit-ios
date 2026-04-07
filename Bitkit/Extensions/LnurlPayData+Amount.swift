import BitkitCore

extension LnurlPayData {
    var minSendableSat: UInt64 {
        LightningAmountConversion.satsCeil(fromMsats: minSendable)
    }

    var maxSendableSat: UInt64 {
        LightningAmountConversion.satsFloor(fromMsats: maxSendable)
    }

    /// True when the LNURL-pay endpoint specifies a single exact amount.
    ///
    /// Also covers the sub-sat edge case where `minSendable` and `maxSendable`
    /// differ in their sub-sat fraction but map to the same (or inverted) sat
    /// range after rounding, e.g. `min=222222, max=222538` → `minSat=223, maxSat=222`.
    var isFixedAmount: Bool {
        minSendable == maxSendable || (minSendable > 0 && minSendableSat > maxSendableSat)
    }

    /// Returns the amount in millisatoshis for the LNURL-pay callback.
    ///
    /// For fixed-amount requests the original msat value is returned verbatim,
    /// avoiding precision loss from the msat→sat→msat round-trip.
    /// For variable-amount requests the user-selected sat amount is converted to msats.
    func callbackAmountMsats(userSats: UInt64? = nil) -> UInt64 {
        if isFixedAmount {
            return minSendable
        }
        return (userSats ?? minSendableSat) * Env.msatsPerSat
    }
}

extension LnurlWithdrawData {
    var minWithdrawableSat: UInt64 {
        LightningAmountConversion.satsCeil(fromMsats: minWithdrawable ?? 0)
    }

    var maxWithdrawableSat: UInt64 {
        LightningAmountConversion.satsFloor(fromMsats: maxWithdrawable)
    }

    /// True when the LNURL-withdraw endpoint specifies a single exact amount,
    /// including the sub-sat edge case where rounding causes `min > max` in whole sats.
    var isFixedAmount: Bool {
        let min = minWithdrawable ?? 0
        return min == maxWithdrawable || (min > 0 && minWithdrawableSat > maxWithdrawableSat)
    }
}
