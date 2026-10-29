enum ReceiveAdditionalLiquidityAction: Equatable {
    case none
    case transferUnavailable
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
        inboundCapacitySats: UInt64?
    ) -> ReceiveAdditionalLiquidityAction {
        guard source == .spending, needsInboundLiquidity(invoiceAmountSats: invoiceAmountSats, inboundCapacitySats: inboundCapacitySats),
              (inboundCapacitySats ?? 0) > 0
        else {
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
