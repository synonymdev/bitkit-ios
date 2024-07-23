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
            //cargo run --release --bin electrs -- -vvv --jsonrpc-import --daemon-rpc-addr 127.0.0.1:18443 --cookie polaruser:polarpass
//            return "https://jaybird-logical-sadly.ngrok-free.app"
            return "http://127.0.0.1:3000"
            
//            return "http://192.168.0.106:3000"
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
//                .init(nodeId: "03e26fdad23b9e17f6a6b1dd0a019c6fcd9e778a1c2af6ae62a0951c8352efbbc3", address: "192.168.0.106:9735")
//                .init(nodeId: "0218ab1da83a4768e154fada54deb5d835199aad116c4212e6844d0dce0f82cab1", address: "192.168.0.106:9737"),
//                .init(nodeId: "021de6ad59a78caf8f376cbd022e8c6ede2a1ef0a4fa035174e8b9c25ad5866584", address: "192.168.0.106:9738")
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
