enum ReceiveAdditionalLiquidityAction: Equatable {
    case none
    case transferUnavailable
    /// The primary node opens or grows the channel for this receive, once the user approves its fee.
    case primaryReceive
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
        hasPrimaryNode: Bool = false
    ) -> ReceiveAdditionalLiquidityAction {
        guard source != .savings, needsInboundLiquidity(invoiceAmountSats: invoiceAmountSats, inboundCapacitySats: inboundCapacitySats)
        else {
            return .none
        }
        if hasPrimaryNode, invoiceAmountSats > 0 {
            return .primaryReceive
        }
        guard source == .spending, (inboundCapacitySats ?? 0) > 0 else {
            return .none
        }

        return .transferUnavailable
    }

    static func needsInboundLiquidity(invoiceAmountSats: UInt64, inboundCapacitySats: UInt64?) -> Bool {
        let inboundCapacitySats = inboundCapacitySats ?? 0

        if invoiceAmountSats == 0 {
            return inboundCapacitySats == 0
        }

        return invoiceAmountSats > inboundCapacitySats
    }
}
