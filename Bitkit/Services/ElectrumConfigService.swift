import Foundation
import SwiftUI

/// Service responsible for managing Electrum server configuration
class ElectrumConfigService {
    @AppStorage("electrumServer") private var electrumServerData = Data()

    init() {}

    /// Gets the current Electrum server URL that should be used for connections
    func getCurrentServer() -> ElectrumServer {
        let storedServer = getStoredServer()
        return storedServer ?? getDefaultServer()
    }

    /// Gets the stored server configuration, if any
    func getStoredServer() -> ElectrumServer? {
        guard !electrumServerData.isEmpty else { return nil }

        do {
            return try JSONDecoder().decode(ElectrumServer.self, from: electrumServerData)
        } catch {
            Logger.error(error, context: "Failed to decode Electrum server config")
            return nil
        }
    }

    /// Gets the default server parsed from Env.electrumServerUrl
    func getDefaultServer() -> ElectrumServer {
        let defaultServerUrl = Env.electrumServerUrl
        let components = defaultServerUrl.split(separator: ":")

        guard components.count >= 2 else {
            fatalError("Invalid default Electrum server URL: \(defaultServerUrl)")
        }

        let host = String(components[0])
        let port = String(components[1])
        let protocolType = getProtocolForPort(port)

        return ElectrumServer(host: host, portString: port, protocolType: protocolType)
    }

    /// Saves Electrum server configuration
    func saveServerConfig(_ server: ElectrumServer) {
        do {
            electrumServerData = try JSONEncoder().encode(server)
            Logger.info("Saved Electrum server config: \(server.url) (\(server.protocolType.rawValue))")
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
