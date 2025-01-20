//
//  Env.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import Foundation
import LDKNode

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

    static let network: LDKNode.Network = .regtest
    static let defaultWalletWordCount = 12
    static let onchainWalletStopGap: UInt64 = 20
    static let walletSyncIntervalSecs: UInt64 = 60
    static let esploraParallelRequests: UInt64 = 6
    static var esploraServerUrl: String {
        switch network {
        case .regtest:
            return "https://bitkit.stag0.blocktank.to/electrs"
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
    
    static func bitkitCoreStorage(walletIndex: Int) -> URL {
        switch network {
        case .regtest:
            return appStorageUrl
                .appendingPathComponent("regtest")
                .appendingPathComponent("wallet\(walletIndex)/core")
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
        
    // TODO: remove this to load from BT API instead
    static var trustedLnPeers: [LnPeer] {
        switch network {
        case .regtest:
            return [
                // Staging Blocktank node
                .init(nodeId: "028a8910b0048630d4eb17af25668cdd7ea6f2d8ae20956e7a06e2ae46ebcb69fc", address: "34.65.86.104:9400")
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
            return "https://api.stag0.blocktank.to"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var blocktankPushNotificationServer: String {
        "\(blocktankBaseUrl)/notifications/api"
    }
    
    static var blocktankClientServer: String {
        "\(blocktankBaseUrl)/blocktank/api/v2"
    }
    
    static var btcRatesServer: String {
        "https://bitkit.stag0.blocktank.to/fx/rates/btc" // TODO: switch to prod when available
    }
    
    static let fxRateRefreshInterval: TimeInterval = 2 * 60 // 2 minutes
    static let fxRateStaleThreshold: TimeInterval = 10 * 60 // After this we notify the user that the rates are stale due to a failed refresh
    
    static var pushNotificationFeatures: [BlocktankNotificationType] = [
        .incomingHtlc,
        .mutualClose,
        .orderPaymentConfirmed,
        .cjitPaymentArrived,
        .wakeToTimeout
    ]
    
    static var vssServerUrl: String {
        switch network {
        case .regtest:
            return "https://bitkit.stag0.blocktank.to/vss"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var vssStoreId: String {
        switch network {
        case .regtest:
            return "bitkit_regtest"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }

    static var termsOfServiceUrl: String {
        "https://www.bitkit.to/terms-of-use"
    }

    static var privacyPolicyUrl: String {
        "https://www.bitkit.to/privacy-policy"
    }
}
