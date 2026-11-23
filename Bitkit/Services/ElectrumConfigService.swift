import Foundation

/// Service responsible for managing Electrum server configuration
class ElectrumConfigService {
    private let defaults: UserDefaults
    private let serverKey = "electrumServer"

    /// Mainnet servers Bitkit used to ship as its default. Both fail TLS now (expired and self-signed certificates),
    /// so the node never starts on them. A wallet carries one only because an older build or a SETTINGS backup
    /// stored the default of its time, so they are dropped in favour of the current default.
    static let retiredDefaultServerUrls: Set<String> = [
        "ssl://fulcrum.bitkit.blocktank.to:8900",
        "ssl://35.187.18.233:8900",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Gets the current Electrum server URL that should be used for connections
    func getCurrentServer() -> ElectrumServer {
        let storedServer = getStoredServer()
        return storedServer ?? getDefaultServer()
    }

    /// Gets the stored server configuration, if any. A stored retired default is cleared and reported as none.
    func getStoredServer() -> ElectrumServer? {
        guard let electrumServerData = defaults.data(forKey: serverKey), !electrumServerData.isEmpty else { return nil }

        let server: ElectrumServer
        do {
            server = try JSONDecoder().decode(ElectrumServer.self, from: electrumServerData)
        } catch {
            Logger.error(error, context: "Failed to decode Electrum server config")
            return nil
        }

        if isRetiredDefault(server) {
            defaults.removeObject(forKey: serverKey)
            Logger.info("Cleared retired default Electrum server: \(server.fullUrl)")
            return nil
        }
        return server
    }

    /// The server a SETTINGS backup should carry: only one the user chose, never the default, so a restore follows
    /// whatever the default is at that time.
    func getCustomServerForBackup() -> ElectrumServer? {
        guard let server = getStoredServer(), !isDefault(server) else { return nil }
        return server
    }

    /// Hostnames are case-insensitive, so a case variant of the default host is the default.
    func isDefault(_ server: ElectrumServer) -> Bool {
        server.fullUrl.lowercased() == getDefaultServer().fullUrl.lowercased()
    }

    func isRetiredDefault(_ server: ElectrumServer) -> Bool {
        Self.retiredDefaultServerUrls.contains(server.fullUrl.lowercased())
    }

    /// Removes the stored server so the default applies
    func clearStoredServer() {
        defaults.removeObject(forKey: serverKey)
    }

    /// Gets the default server parsed from Env.electrumServerUrl
    func getDefaultServer() -> ElectrumServer {
        let defaultServerUrl = Env.electrumServerUrl

        guard defaultServerUrl.hasPrefix("tcp://") || defaultServerUrl.hasPrefix("ssl://") else {
            fatalError("Invalid default Electrum server URL format: \(defaultServerUrl). Expected tcp:// or ssl:// prefix.")
        }

        let protocolType: ElectrumProtocol = defaultServerUrl.hasPrefix("ssl://") ? .ssl : .tcp
        let urlWithoutProtocol = String(defaultServerUrl.dropFirst(6)) // Remove "ssl://" or "tcp://"
        let components = urlWithoutProtocol.split(separator: ":")

        guard components.count >= 2 else {
            fatalError("Invalid default Electrum server URL: \(defaultServerUrl)")
        }

        let host = String(components[0])
        let port = String(components[1])

        return ElectrumServer(host: host, portString: port, protocolType: protocolType)
    }

    /// Saves Electrum server configuration
    func saveServerConfig(_ server: ElectrumServer) {
        do {
            let data = try JSONEncoder().encode(server)
            defaults.set(data, forKey: serverKey)
            Logger.info("Saved Electrum server config: \(server.fullUrl)")
        } catch {
            Logger.error(error, context: "Failed to encode Electrum server config")
        }
    }

    /// Gets the protocol for a given port
    func getProtocolForPort(_ port: String) -> ElectrumProtocol {
        if port == "443" {
            return .ssl
        }

        if Env.network == .testnet {
            return port == "51002" ? .ssl : .tcp
        }

        return port == "50002" ? .ssl : .tcp
    }
}
