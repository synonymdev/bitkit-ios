import Foundation

struct BtChannelClose: Codable {
    /**
     * Transaction id of the closing transaction. Only available if state === OpenChannelOrderState.CLOSED.
     */
    var txId: String
    /**
     * Which method has been used to close this channel?
     */
    var type: CloseType
    /**
     * Who closed this channel?
     */
    var initiator: Initiator
    /**
     * When Blocktank registered the channel close.
     */
    var registeredAt: String
}

enum CloseType: String, Codable {
    case cooperative = "cooperative"
    case force = "force"
    case breach = "breach"
}

enum Initiator: String, Codable {
    case lsp = "lsp"
    case client = "client"
}