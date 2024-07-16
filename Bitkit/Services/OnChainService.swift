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
        
        Logger.debug("Creating onchain wallet...")
        
        try await ServiceQueue.background(.bdk) {
            self.wallet = try Wallet(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                network: Env.network.bdkNetwork,
                databaseConfig: .memory //TODO use sqlite
            )
        }
        
        Logger.info("Onchain wallet created")
    }
    
    func getAddress() async throws -> String {
        guard let wallet else {
            throw AppError(serviceError: .onchainWalletNotCreated)
        }
        
        return try await ServiceQueue.background(.bdk) {
            let addressInfo = try wallet.getAddress(addressIndex: .new)
            return addressInfo.address.asString()
        }
    }
    
    func sync() async throws {
        guard let wallet, let blockchainConfig else {
            throw AppError(serviceError: .onchainWalletNotCreated)
        }
        
        Logger.debug("Syncing BDK...")
        
        let blockchain = try Blockchain(config: blockchainConfig)
        
        try await ServiceQueue.background(.bdk) {
            try wallet.sync(blockchain: blockchain, progress: nil)
        }
        
        Logger.info("BDK synced")
    }
}

//MARK: UI Helpers (Published via OnChainViewModel)
extension OnChainService {
    //TODO catch errors?
    var balance: Balance? { try? wallet?.getBalance() }
}
