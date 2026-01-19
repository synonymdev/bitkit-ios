import BitkitCore
import LDKNode

/// Helper for validating Bitcoin network compatibility of addresses and invoices
enum NetworkValidationHelper {
    /// Convert BitkitCore.Network to LDKNode.Network
    /// - Parameter network: The BitkitCore network
    /// - Returns: The equivalent LDKNode network
    static func convertNetwork(_ network: BitkitCore.Network) -> LDKNode.Network {
        switch network {
        case .bitcoin: return .bitcoin
        case .testnet: return .testnet
        case .signet: return .signet
        case .regtest: return .regtest
        }
    }

    /// Convert BitkitCore.NetworkType to LDKNode.Network
    /// - Parameter networkType: The BitkitCore network type
    /// - Returns: The equivalent LDKNode network
    static func convertNetworkType(_ networkType: NetworkType) -> LDKNode.Network {
        switch networkType {
        case .bitcoin: return .bitcoin
        case .testnet: return .testnet
        case .signet: return .signet
        case .regtest: return .regtest
        }
    }

    /// Check if an address/invoice network mismatches the current app network
    /// - Parameters:
    ///   - addressNetwork: The network detected from the address/invoice
    ///   - currentNetwork: The app's current network (typically Env.network)
    /// - Returns: true if there's a mismatch (address won't work on current network)
    static func isNetworkMismatch(addressNetwork: LDKNode.Network?, currentNetwork: LDKNode.Network) -> Bool {
        guard let addressNetwork else { return false }

        // Special case: regtest uses testnet prefixes (m, n, 2, tb1)
        if currentNetwork == .regtest && addressNetwork == .testnet {
            return false
        }

        return addressNetwork != currentNetwork
    }
}
