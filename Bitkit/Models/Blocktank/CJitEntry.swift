import Foundation

struct CJitEntry: Codable {
    /**
     * Id of this CJitEntry
     */
    var id: String
    /**
     * State of this entry
     */
    var state: CJitStateEnum
    /**
     * Fee in satoshi to open this channel.
     */
    var feeSat: Int
    /**
     * Requested channel size in satoshi
     */
    var channelSizeSat: Int
    /**
     * Number of weeks before Blocktank might close then channel.
     */
    var channelExpiryWeeks: Int
    /**
     * Channel open error if the channel open failed.
     */
    var channelOpenError: String?
    /**
     * Node id of the node to open the channel to.
     */
    var nodeId: String
    /**
     * Invoice to be paid for the channel open.
     */
    var invoice: BtBolt11Invoice
    /**
     * Opened channel
     */
    var channel: BtChannel?
    /**
     * LSP node the channel is opened from. The client needs to establish a peer connection to it before the channel open.
     */
    var lspNode: LspNode
    /**
     * @deprecated Use `source` instead
     */
    var couponCode: String
    /**
     * Source what created this Cjit. Example: 'bitkit', 'widget'.
     */
    var source: String?
    /**
     * Discount if available
     */
    var discount: Discount?
    /**
     * Date when this CJit offer expires.
     */
    var expiresAt: Date
    var updatedAt: Date
    var createdAt: Date
}
