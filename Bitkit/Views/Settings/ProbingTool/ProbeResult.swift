import Foundation

struct ProbeResult {
    let success: Bool
    let durationMs: Int
    let routeFeeMsat: UInt64?
    let errorMessage: String?
}
