import Foundation
import SwiftUI

/// Service responsible for managing geoblocking state
class GeoService: ObservableObject {
    static let shared = GeoService()

    /// Current geoblocking status
    /// - `false`: User is not geoblocked (default/fallback if check fails)
    /// - `true`: User is geoblocked
    @Published var isGeoBlocked: Bool = false

    private let coreService: CoreService

    private init(coreService: CoreService = .shared) {
        self.coreService = coreService
    }

    /// Checks the current geoblocking status and updates the published state
    func checkGeoStatus() async {
        do {
            let result = try await coreService.checkGeoStatus()

            let newValue = result ?? false

            await MainActor.run {
                self.isGeoBlocked = newValue
            }

            Logger.info("Geo status check completed: isGeoBlocked=\(isGeoBlocked)", context: "GeoService")
        } catch {
            isGeoBlocked = false
            Logger.error("Failed to check geo status: \(error)", context: "GeoService")
        }
    }
}
