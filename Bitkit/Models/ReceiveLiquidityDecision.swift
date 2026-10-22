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
}
