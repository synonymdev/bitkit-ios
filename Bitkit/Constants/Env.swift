//
//  Env.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import Foundation

struct Env {
    static let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    static let isUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
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
    
    //MARK: wallet services
    static let network: WalletNetwork = .regtest
    static var esploraServerUrl: String {
        switch network {
        case .regtest:
            return "https://electrs-regtest.synonym.to"
            //cargo run --release --bin electrs -- -vvv --jsonrpc-import --daemon-rpc-addr 127.0.0.1:18443 --cookie polaruser:polarpass
            //return "http://127.0.0.1:3000"            
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var appStorageUrl: URL {
        //App group so files can be shared with extensions
        guard let documentsDirectory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.bitkit") else {
            fatalError("Could not find documents directory")
        }
        
        if isUnitTest {
            return documentsDirectory.appendingPathComponent("unit-tests")
        }
        
        return documentsDirectory
    }
    
    static var ldkStorage: URL {
        switch network {
        case .regtest:
            return appStorageUrl.appendingPathComponent("regtest").appendingPathComponent("ldk")
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var bdkStorage: URL {
        switch network {
        case .regtest:
            return appStorageUrl.appendingPathComponent("regtest").appendingPathComponent("bdk")
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
                .init(nodeId: "02b61365f14c5070465e014485fa91cee5a131cf2a4b7cb37309fcd1cc53975238", address: "192.168.0.106:9735")
            ]
        case .bitcoin:
            return []
        case .testnet:
            return []
        case .signet:
            return []
        }
    }
    
    static let testMnemonic = "pool curve feature leader elite dilemma exile toast smile couch crane public"
}
