import Foundation

struct BtChannel: Codable {
    var state: BtOpenChannelState_OLD
    var lspNodePubkey: String
    var clientNodePubkey: String
    var announceChannel: Bool
    var fundingTx: FundingTx
    var closingTxId: String?
    var close: BtChannelClose?
    var shortChannelId: String?

    struct FundingTx: Codable {
        var id: String
        var vout: Int
    }
}
