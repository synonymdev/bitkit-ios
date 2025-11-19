import Foundation
import SwiftUI

/// Service responsible for managing geoblocking state
/// This is the single source of truth for geoblocking status in the app
@MainActor
@Observable
class GeoService {
    static let shared = GeoService()

    /// Current geoblocking status
    /// - `false`: User is not geoblocked (default/fallback if check fails)
    /// - `true`: User is geoblocked
    var isGeoBlocked: Bool = false

    private let coreService: CoreService

    private init(coreService: CoreService = .shared) {
        self.coreService = coreService
    }

    /// Checks the current geoblocking status and updates the published state
    /// Uses CoreService to make the HTTP request to the geo-check endpoint
    func checkGeoStatus() async {
        do {
            let result = try await coreService.checkGeoStatus()

            // Handle nil response from CoreService (network error, invalid response, etc.)
            // Default to false (not blocked) as a safe fallback
            isGeoBlocked = result ?? false

            Logger.info("Geo status check completed: isGeoBlocked=\(isGeoBlocked)", context: "GeoService")
        } catch {
            // On error, default to not blocked (safe fallback)
            isGeoBlocked = false
            Logger.error("Failed to check geo status: \(error)", context: "GeoService")
        }
    }
}
