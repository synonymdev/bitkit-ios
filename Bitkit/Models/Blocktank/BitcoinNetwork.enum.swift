import Foundation

enum BitcoinNetworkEnum: String, Codable {
    case mainnet = "mainnet"
    case testnet = "testnet"
    case signet = "signet"
    case regtest = "regtest"
}