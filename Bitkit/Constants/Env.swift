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
            return "https://jaybird-logical-sadly.ngrok-free.app"
            //            return "http://localhost:3000"
        case .bitcoin:
            fatalError("Bitcoin network not implemented")
        case .testnet:
            fatalError("Testnet network not implemented")
        case .signet:
            fatalError("Signet network not implemented")
        }
    }
    
    static var appStorageUrl: URL {
        //TODO move to app group so files can be shared with extensions
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Could not find documents directory")
        }
        
        return documentsDirectory
    }
    
    static var ldkStorage: URL {
        let storageDirPath = appStorageUrl.appendingPathComponent("ldk")
        
        switch network {
        case .regtest:
            return storageDirPath.appendingPathComponent("regtest")
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
            return [.init(nodeId: "021de6ad59a78caf8f376cbd022e8c6ede2a1ef0a4fa035174e8b9c25ad5866584", address: "127.0.0.1:9736")]
        case .bitcoin:
            return []
        case .testnet:
            return []
        case .signet:
            return []
        }
    }
}
