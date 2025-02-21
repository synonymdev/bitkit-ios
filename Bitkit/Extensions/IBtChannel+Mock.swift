import Foundation

extension IBtChannel {
    static func mock(state: BtOpenChannelState = .opening) -> IBtChannel {
        return IBtChannel(
            state: state,
            lspNodePubkey: "03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad",
            clientNodePubkey: "02eadbd9e7557375161df8b646776a547c5cbc2e95b3071ec81553f8ec2cea3b8c",
            announceChannel: false,
            fundingTx: FundingTx(
                id: "txid123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                vout: 0
            ),
            closingTxId: nil,
            close: nil,
            shortChannelId: nil
        )
    }
}
