import Foundation

enum CJitStateEnum: String, Codable {
    case created = "created"
    case completed = "completed"
    case expired = "expired"
    case failed = "failed"
}