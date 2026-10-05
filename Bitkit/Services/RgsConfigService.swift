import Foundation

/// Service responsible for managing RGS server configuration
class RgsConfigService {
    private let defaults: UserDefaults
    private let serverKey = "rapidGossipSyncUrl"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Gets the current RGS server URL that should be used for connections
    func getCurrentServerUrl() -> String {
        let rapidGossipSyncUrl = defaults.string(forKey: serverKey) ?? ""
        return rapidGossipSyncUrl.isEmpty ? getDefaultServerUrl() : rapidGossipSyncUrl
    }

    /// Gets the default server from Env.ldkRgsServerUrl
    func getDefaultServerUrl() -> String {
        return Env.ldkRgsServerUrl ?? ""
    }

    /// Saves RGS server configuration
    func saveServerUrl(_ url: String) {
        defaults.set(url, forKey: serverKey)
        Logger.info("Saved RGS server URL: \(url)")
    }

    /// Checks if the current URL is the default
    func isDefaultUrl(_ url: String) -> Bool {
        return url == getDefaultServerUrl()
    }
}
