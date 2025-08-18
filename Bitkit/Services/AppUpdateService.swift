import Foundation
import UIKit

struct AppUpdateInfo: Codable {
    let buildNumber: Int
    let version: String
    let url: String
    let notes: String?
    let critical: Bool
}

struct AppUpdateRelease: Codable {
    let platforms: [String: AppUpdateInfo]
}

class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    @MainActor @Published var availableUpdate: AppUpdateInfo?

    private init() {}

    /// Check for app updates by comparing build numbers
    func checkForAppUpdate() async {
        do {
            let currentBuild = getCurrentBuildNumber()
            Logger.debug("Current build number: \(currentBuild)", context: "AppUpdateService")

            guard let url = URL(string: Env.updaterUrl) else {
                Logger.error("Invalid release URL", context: "AppUpdateService")
                return
            }

            let (data, _) = try await URLSession.shared.data(from: url)
            let releases = try JSONDecoder().decode(AppUpdateRelease.self, from: data)

            guard let iosRelease = releases.platforms["ios"] else {
                Logger.error("No iOS release found in update data", context: "AppUpdateService")
                return
            }

            Logger.debug("Latest build number: \(iosRelease.buildNumber)", context: "AppUpdateService")

            let updateAvailable = iosRelease.buildNumber > currentBuild

            if updateAvailable {
                Logger.info("App update available: \(iosRelease.version) (build \(iosRelease.buildNumber))", context: "AppUpdateService")
                await MainActor.run {
                    availableUpdate = iosRelease
                }
            } else {
                Logger.debug("No app update available", context: "AppUpdateService")
                await MainActor.run {
                    availableUpdate = nil
                }
            }

        } catch {
            Logger.error("Failed to check for app update: \(error)", context: "AppUpdateService")
        }
    }

    /// Get the current app build number
    private func getCurrentBuildNumber() -> Int {
        guard let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let buildNumber = Int(buildString)
        else {
            Logger.error("Could not get current build number", context: "AppUpdateService")
            return 0
        }
        return buildNumber
    }
}
