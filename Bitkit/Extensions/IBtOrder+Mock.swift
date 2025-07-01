import BitkitCore
import Foundation

extension IBtOrder {
    static func mock(
        state2: BtOrderState2 = .created,
        channel: IBtChannel? = nil,
        lspBalanceSat: UInt64 = 50000,
        clientBalanceSat: UInt64 = 85967
    ) -> IBtOrder {
        return IBtOrder(
            id: "order123",
            state: .created,
            state2: state2,
            feeSat: 1000,
            networkFeeSat: 2483,
            serviceFeeSat: 1520,
            lspBalanceSat: lspBalanceSat,
            clientBalanceSat: clientBalanceSat,
            zeroConf: false,
            zeroReserve: false,
            clientNodeId: "node123",
            channelExpiryWeeks: 52,
            channelExpiresAt: "2025-03-14T10:30:00Z",
            orderExpiresAt: "2024-03-21T15:45:00Z",
            channel: channel,
            lspNode: .init(alias: "", pubkey: "", connectionStrings: [], readonly: nil),
            lnurl: nil,
            payment: IBtPayment(
                state: .created,
                state2: .created,
                paidSat: 0,
                bolt11Invoice: IBtBolt11Invoice(
                    request: "lnbc...",
                    state: .pending,
                    expiresAt: "2024-03-21T15:45:00Z",
                    updatedAt: "2024-03-14T08:20:00Z"
                ),
                onchain: IBtOnchainTransactions(
                    address: "bc1q...",
                    confirmedSat: 0,
                    requiredConfirmations: 3,
                    transactions: []
                ),
                isManuallyPaid: nil,
                manualRefunds: nil
            ),
            couponCode: nil,
            source: nil,
            discount: nil,
            updatedAt: "2024-03-14T08:20:00Z",
            createdAt: "2024-03-14T08:15:00Z"
        )
    }
}
