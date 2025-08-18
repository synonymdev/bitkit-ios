import Foundation
import LDKNode
import UIKit

enum BlockExplorerService: String, CaseIterable {
    case blockstream
    case mempool
}

enum BlockExplorerType: String {
    case tx
    case address
}

enum BlockExplorerHelper {
    /// Generates a block explorer URL for the given ID and type
    /// - Parameters:
    ///   - id: The transaction ID or address to look up
    ///   - type: Whether this is a transaction or address lookup
    ///   - network: The network to use (defaults to current Env.network)
    ///   - service: Which block explorer service to use
    /// - Returns: The complete URL string for the block explorer
    static func getBlockExplorerLink(
        id: String,
        type: BlockExplorerType = .tx,
        network: LDKNode.Network = Env.network,
        service: BlockExplorerService = .mempool
    ) -> String {
        let isTestnet = network != .bitcoin

        switch service {
        case .blockstream:
            if isTestnet {
                return "https://blockstream.info/testnet/\(type.rawValue)/\(id)"
            }
            return "https://blockstream.info/\(type.rawValue)/\(id)"

        case .mempool:
            if isTestnet {
                return "https://mempool.space/testnet/\(type.rawValue)/\(id)"
            }
            return "https://mempool.space/\(type.rawValue)/\(id)"
        }
    }

    /// Opens the block explorer link in the default browser
    /// - Parameters:
    ///   - id: The transaction ID or address to look up
    ///   - type: Whether this is a transaction or address lookup
    ///   - network: The network to use (defaults to current Env.network)
    ///   - service: Which block explorer service to use
    static func openBlockExplorer(
        id: String,
        type: BlockExplorerType = .tx,
        network: LDKNode.Network = Env.network,
        service: BlockExplorerService = .mempool
    ) {
        let urlString = getBlockExplorerLink(id: id, type: type, network: network, service: service)

        guard let url = URL(string: urlString) else {
            Logger.error("Invalid block explorer URL: \(urlString)", context: "BlockExplorerHelper")
            return
        }

        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            Logger.error("Cannot open block explorer URL: \(urlString)", context: "BlockExplorerHelper")
        }
    }
}
