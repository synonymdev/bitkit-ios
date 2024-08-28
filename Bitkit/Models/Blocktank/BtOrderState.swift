import Foundation

enum BtOrderState: String, Codable {
    case created = "created"
    case expired = "expired"
    case open = "open"
    case closed = "closed"
}