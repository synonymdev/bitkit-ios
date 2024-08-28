import Foundation

enum BtOpenChannelState: String, Codable {
    case opening = "opening"
    case open = "open"
    case closed = "closed"
}