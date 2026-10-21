import BitkitCore
import LDKNode

extension LDKNode.Network {
    /// The network a Jade is asked to use. Jade has no signet; its regtest is named "localtest" on
    /// the wire, which bitkit-core maps.
    func toJadeNetwork() throws -> JadeNetwork {
        switch self {
        case .bitcoin: .mainnet
        case .testnet: .testnet
        case .regtest: .regtest
        case .signet: throw AppError(message: "Signet is not supported by Jade", debugMessage: nil)
        }
    }
}

extension LDKNode.AddressType {
    /// The Jade script variant of this address type, as used to verify an address on the device.
    var jadeVariant: JadeAddressVariant {
        switch self {
        case .legacy: .pkh
        case .nestedSegwit: .shWpkh
        case .nativeSegwit: .wpkh
        case .taproot: .tr
        }
    }

    init(jadeVariant: JadeAddressVariant) {
        switch jadeVariant {
        case .pkh: self = .legacy
        case .shWpkh: self = .nestedSegwit
        case .wpkh: self = .nativeSegwit
        case .tr: self = .taproot
        }
    }
}
