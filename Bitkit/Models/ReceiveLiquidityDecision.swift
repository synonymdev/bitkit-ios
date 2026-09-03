enum ReceiveAdditionalLiquidityAction: Equatable {
    case none
    case chooseAmount
    case createCjit(UInt64)
    case geoBlocked
}

enum ReceiveLiquiditySource: Equatable {
    case savings
    case auto
    case spending
}

enum ReceiveLiquidityDecision {
    static func canCreateLightningInvoice(
        hasReadyChannels: Bool,
        inboundCapacitySats: UInt64?,
        invoiceAmountSats: UInt64?
    ) -> Bool {
        guard hasReadyChannels, let inboundCapacitySats else {
            return false
        }

        guard let invoiceAmountSats, invoiceAmountSats > 0 else {
            return inboundCapacitySats > 0
        }

        return invoiceAmountSats <= inboundCapacitySats
    }

    static func additionalLiquidityAction(
        source: ReceiveLiquiditySource,
        invoiceAmountSats: UInt64,
        inboundCapacitySats: UInt64?,
        minCjitSats: UInt64?,
        maxCjitAmountSats: UInt64?,
        isGeoBlocked: Bool
    ) -> ReceiveAdditionalLiquidityAction {
        guard source == .spending else {
            return .none
        }

        guard needsInboundLiquidity(invoiceAmountSats: invoiceAmountSats, inboundCapacitySats: inboundCapacitySats) else {
            return .none
        }

        let inboundCapacitySats = inboundCapacitySats ?? 0
        if inboundCapacitySats == 0 {
            return .none
        }

        if isGeoBlocked {
            return .geoBlocked
        }

        let minCjitSats = minCjitSats ?? 0
        guard let maxCjitAmountSats, maxCjitAmountSats > 0 else {
            return .chooseAmount
        }

        if invoiceAmountSats == 0 || minCjitSats == 0 || invoiceAmountSats < minCjitSats || invoiceAmountSats > maxCjitAmountSats {
            return .chooseAmount
        }

        return .createCjit(invoiceAmountSats)
    }

    static func needsCjitLimitsForAdditionalLiquidity(
        source: ReceiveLiquiditySource,
        invoiceAmountSats: UInt64,
        inboundCapacitySats: UInt64?,
        isGeoBlocked: Bool
    ) -> Bool {
        guard source == .spending else {
            return false
        }

        guard needsInboundLiquidity(invoiceAmountSats: invoiceAmountSats, inboundCapacitySats: inboundCapacitySats) else {
            return false
        }

        guard (inboundCapacitySats ?? 0) > 0 else {
            return false
        }

        return !isGeoBlocked
    }

    static func needsInboundLiquidity(invoiceAmountSats: UInt64, inboundCapacitySats: UInt64?) -> Bool {
        let inboundCapacitySats = inboundCapacitySats ?? 0

        if invoiceAmountSats == 0 {
            return inboundCapacitySats == 0
        }

        return invoiceAmountSats > inboundCapacitySats
    }
}
