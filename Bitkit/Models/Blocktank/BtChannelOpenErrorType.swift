import Foundation

enum BtChannelOrderErrorType_OLD: String, Codable {
    /**
     * Order is not in the right state to open a channel. Should be `order.state`=`created` and `order.payment.state`=`paid`.
     */
    case wrongOrderState = "WRONG_ORDER_STATE"
    
    /**
     * Could not establish connection to peer.
     * */
    case peerNotReachable = "PEER_NOT_REACHABLE"
    
    /**
     * Peer rejected channel open request.
     */
    case channelRejectedByDestination = "CHANNEL_REJECTED_BY_DESTINATION"
    
    /**
     * LSP rejected channel open request.
     */
    case channelRejectedByLsp = "CHANNEL_REJECTED_BY_LSP"
    
    /**
     * Blocktank service is temporarily unavailable.
     */
    case blocktankNotReady = "BLOCKTANK_NOT_READY"
}
