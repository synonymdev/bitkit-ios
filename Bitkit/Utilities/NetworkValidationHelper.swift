import BitkitCore
import LDKNode

/// Helper for validating Bitcoin network compatibility of addresses and invoices
enum NetworkValidationHelper {
    /// Infer the Bitcoin network from an on-chain address prefix
    /// - Parameter address: The Bitcoin address to check
    /// - Returns: The detected network, or nil if the address format is unrecognized
    static func getAddressNetwork(_ address: String) -> LDKNode.Network? {
        let lowercased = address.lowercased()

        // Bech32/Bech32m addresses (order matters: check bcrt1 before bc1)
        if lowercased.hasPrefix("bcrt1") {
            return .regtest
        } else if lowercased.hasPrefix("bc1") {
            return .bitcoin
        } else if lowercased.hasPrefix("tb1") {
            return .testnet
        }

        // Legacy addresses - check first character
        guard let first = address.first else { return nil }
        switch first {
        case "1", "3": return .bitcoin
        case "m", "n", "2": return .testnet // testnet and regtest share these
        default: return nil
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
