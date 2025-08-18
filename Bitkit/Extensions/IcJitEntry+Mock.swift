import BitkitCore
import Foundation

extension IcJitEntry {
    static func mock(
        state: CJitStateEnum = .created,
        channelSizeSat: UInt64 = 100_000,
        feeSat: UInt64 = 1000,
        channelExpiryWeeks: UInt32 = 6,
        channel: IBtChannel? = nil
    ) -> IcJitEntry {
        return IcJitEntry(
            id: "test-cjit-id",
            state: state,
            feeSat: feeSat,
            networkFeeSat: 500,
            serviceFeeSat: 500,
            channelSizeSat: channelSizeSat,
            channelExpiryWeeks: channelExpiryWeeks,
            channelOpenError: nil,
            nodeId: "node-id-123456",
            invoice: IBtBolt11Invoice(
                request: "lnbc100000...",
                state: .pending,
                expiresAt: "2024-10-28T12:00:00Z",
                updatedAt: "2024-10-21T12:00:00Z"
            ),
            channel: channel,
            lspNode: ILspNode(
                alias: "Test LSP",
                pubkey: "lsp-pubkey-123456",
                connectionStrings: ["127.0.0.1:9735"],
                readonly: nil
            ),
            couponCode: "",
            source: "bitkit-ios",
            discount: nil,
            expiresAt: "2024-10-28T12:00:00Z",
            updatedAt: "2024-10-21T12:00:00Z",
            createdAt: "2024-10-21T12:00:00Z"
        )
    }
}
