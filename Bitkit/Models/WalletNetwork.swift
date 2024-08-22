//
//  Network.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import BitcoinDevKit
import Foundation
import LDKNode

enum WalletNetwork {
    case regtest
    case bitcoin
    case testnet
    case signet

    var displayName: String {
        switch self {
        case .regtest:
            return "Regtest"
        case .bitcoin:
            return "Bitcoin"
        case .testnet:
            return "Testnet"
        case .signet:
            return "Signet"
        }
    }

    var ldkNetwork: LDKNode.Network {
        switch self {
        case .regtest:
            return .regtest
        case .bitcoin:
            return .bitcoin
        case .testnet:
            return .testnet
        case .signet:
            return .signet
        }
    }

    var bdkNetwork: BitcoinDevKit.Network {
        switch self {
        case .regtest:
            return .regtest
        case .bitcoin:
            return .bitcoin
        case .testnet:
            return .testnet
        case .signet:
            return .signet
        }
    }
}
