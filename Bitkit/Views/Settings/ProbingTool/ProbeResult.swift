import Foundation

struct ProbeResult {
    let success: Bool
    let durationMs: Int
    let estimatedFeeSats: UInt64?
    let errorMessage: String?
}
