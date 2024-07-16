//
//  OnChainService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import Foundation
import BitcoinDevKit

class OnChainService {
    private var wallet: Wallet?
    private var blockchainConfig: BlockchainConfig?
    
    static var shared: OnChainService = OnChainService()
    
    private init() {}
    
    func setup() throws {
        //TODO maybe better as a lazy var
        let esploraConfig = EsploraConfig(
            baseUrl: Env.esploraServerUrl,
            proxy: nil,
            concurrency: nil,
            stopGap: UInt64(20),
            timeout: nil
        )
        
        blockchainConfig = BlockchainConfig.esplora(config: esploraConfig)
    }
    
    func createWallet(mnemonic: String, passphrase: String?) async throws {
        let mnemonic = try Mnemonic.fromString(mnemonic: mnemonic)
        
        let secretKey = DescriptorSecretKey(
            network: Env.network.bdkNetwork,
            mnemonic: mnemonic,
            password: passphrase
        )
        
        let descriptor = Descriptor.newBip86(
            secretKey: secretKey,
            keychain: .external,
            network: Env.network.bdkNetwork
        )
        
        let changeDescriptor = Descriptor.newBip86(
            secretKey: secretKey,
            keychain: .internal,
            network: Env.network.bdkNetwork
        )
        
        //TODO save to keychain
        
        try await ServiceQueue.background(.bdk) {
            self.wallet = try Wallet(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                network: Env.network.bdkNetwork,
                databaseConfig: .memory //TODO use sqlite
            )
        }
    }
    
    func getAddress() throws -> String {
        guard let wallet else {
            //TODO throw custom error
            return "error"
        }
        let addressInfo = try wallet.getAddress(addressIndex: .new)
        return addressInfo.address.asString()
    }
    
    func sync() async throws {
        guard let wallet, let blockchainConfig else {
            //TODO throw custom error
            return
        }
        let blockchain = try Blockchain(config: blockchainConfig)
        
        try await ServiceQueue.background(.bdk) {
            try wallet.sync(blockchain: blockchain, progress: nil)
        }
    }
}

//MARK: UI Helpers (Published via OnChainViewModel)
extension OnChainService {
    //TODO catch errors?
    var balance: Balance? { try? wallet?.getBalance() }
}
