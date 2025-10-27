import Foundation
import SwiftUI

/// Service responsible for managing RGS server configuration
class RgsConfigService {
    @AppStorage("rapidGossipSyncUrl") private var rapidGossipSyncUrl: String = ""

    init() {}

    /// Gets the current RGS server URL that should be used for connections
    func getCurrentServerUrl() -> String {
        return rapidGossipSyncUrl.isEmpty ? getDefaultServerUrl() : rapidGossipSyncUrl
    }

    /// Gets the default server from Env.ldkRgsServerUrl
    func getDefaultServerUrl() -> String {
        return Env.ldkRgsServerUrl ?? ""
    }

    /// Saves RGS server configuration
    func saveServerUrl(_ url: String) {
        rapidGossipSyncUrl = url
        Logger.info("Saved RGS server URL: \(url)")
    }

    /// Checks if the current URL is the default
    func isDefaultUrl(_ url: String) -> Bool {
        return url == getDefaultServerUrl()
    }
}
