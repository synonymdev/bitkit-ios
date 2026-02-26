import BitkitCore
import Foundation
import SwiftUI

/// Single source of truth for on-chain fee estimates (fast/mid/slow). Fetches and caches
/// When the dev "override fees" setting is on, returns fixed rates for UI work without hitting the backend.
@MainActor
final class FeeEstimatesManager: ObservableObject {
    @Published private(set) var estimates: FeeRates?

    /// Dev setting: use hardcoded fee rates for UI development. Toggle is in Dev settings (regtest).
    @AppStorage("devOverrideFeeEstimates") var devOverrideFeeEstimates = false

    private let coreService: CoreService

    init(coreService: CoreService = .shared) {
        self.coreService = coreService
    }

    /// Fetches fee rates and updates the cache.
    /// - Parameter refresh: If true, forces a fresh fetch; otherwise may use backend cache.
    /// - Returns: Current fee rates, or nil if unavailable.
    @discardableResult
    func getEstimates(refresh: Bool = false) async -> FeeRates? {
        if devOverrideFeeEstimates {
            let rates = FeeRates(fast: 10, mid: 7, slow: 3)
            estimates = rates
            return rates
        }

        do {
            let rates = try await coreService.blocktank.fees(refresh: refresh)
            estimates = rates
            return rates
        } catch {
            Logger.error("Failed to get fee estimates: \(error)", context: "FeeEstimatesManager")
            return nil
        }
    }
}
