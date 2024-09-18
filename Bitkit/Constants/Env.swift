//
//  Env.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import BitcoinDevKit
import Foundation

enum Env {
    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    static let isUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    // {Team ID}.{Keychain Group}
    static let keychainGroup = "KYH47R284B.to.bitkit"
    
    #if targetEnvironment(simulator)
        static let isSim = true
    #else
        static let isSim = false
    #endif
    
    #if DEBUG
        static let isDebug = true
    #else
        static let isDebug = false
    #endif
    
    // MARK: wallet services

    static let network: WalletNetwork = .regtest
    static let defaultWalletWordCount: WordCount = .words12
    static let onchainWalletStopGap = UInt64(20)
    static let esploraParallelRequests = UInt64(5)
    static var esploraServerUrl: String {
        switch network {
        case .regtest:
            return "https://electrs-regtest.synonym.to"
        // cargo run --release --bin electrs -- -vvv --jsonrpc-import --daemon-rpc-addr 127.0.0.1:18443 --cookie polaruser:polarpass
        // return "http://127.0.0.1:3000"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var appStorageUrl: URL {
        // App group so files can be shared with extensions
        guard let documentsDirectory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bitkit") else {
            fatalError("Could not find documents directory")
        }
        
        if isUnitTest {
            return documentsDirectory.appendingPathComponent("unit-tests")
        }
        
        return documentsDirectory
    }
    
    static func ldkStorage(walletIndex: Int) -> URL {
        switch network {
        case .regtest:
            return appStorageUrl
                .appendingPathComponent("regtest")
                .appendingPathComponent("wallet\(walletIndex)/ldk")
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static func bdkStorage(walletIndex: Int) -> URL {
        switch network {
        case .regtest:
            return appStorageUrl
                .appendingPathComponent("regtest")
                .appendingPathComponent("wallet\(walletIndex)/bdk")
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var ldkRgsServerUrl: String? {
        switch network {
        case .regtest:
            return nil
        case .bitcoin:
            return "https://rapidsync.lightningdevkit.org/snapshot/"
        case .testnet:
            return nil
        case .signet:
            return nil
        }
    }
    
    static var trustedLnPeers: [LnPeer] {
        switch network {
        case .regtest:
            return [
                // Staging Blocktank node
                .init(nodeId: "03b9a456fb45d5ac98c02040d39aec77fa3eeb41fd22cf40b862b393bcfc43473a", address: "35.233.47.252:9400")
            ]
        case .bitcoin:
            return []
        case .testnet:
            return []
        case .signet:
            return []
        }
    }
    
    static var blocktankBaseUrl: String {
        switch network {
        case .regtest:
            return "https://api.stag.blocktank.to"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var blocktankPushNotificationServer: String {
        return "\(blocktankBaseUrl)/notifications/api"
    }
    
    static var blocktankClientServer: String {
        return "\(blocktankBaseUrl)/blocktank/api/v2"
    }
    
    static var pushNotificationFeatures: [BlocktankNotificationType] = [
        .incomingHtlc,
        .mutualClose,
        .orderPaymentConfirmed,
        .cjitPaymentArrived,
        .wakeToTimeout
    ]
}
