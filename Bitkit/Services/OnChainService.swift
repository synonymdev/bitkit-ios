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
    var currentWalletIndex: Int = 0
    
    private var blockchainConfig: BlockchainConfig {
        let esploraConfig = EsploraConfig(
            baseUrl: Env.esploraServerUrl,
            proxy: nil,
            concurrency: nil,
            stopGap: Env.onchainWalletStopGap,
            timeout: nil
        )
        
        return BlockchainConfig.esplora(config: esploraConfig)
    }
    
    static var shared = OnChainService()
    private init() {}
    
    func setup(walletIndex: Int) async throws {
        guard var mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        
        var passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        
        currentWalletIndex = walletIndex
                
        let secretKey = DescriptorSecretKey(
            network: Env.network.bdkNetwork,
            mnemonic: try Mnemonic.fromString(mnemonic: mnemonic),
            password: passphrase
        )
        
        let descriptor = Descriptor.newBip84(
            secretKey: secretKey,
            keychain: .external,
            network: Env.network.bdkNetwork
        )
        
        let changeDescriptor = Descriptor.newBip84(
            secretKey: secretKey,
            keychain: .internal,
            network: Env.network.bdkNetwork
        )
        
        //TODO save to keychain
        
        Logger.debug("Creating onchain wallet...")
        
        let bdkStorage = Env.bdkStorage(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: bdkStorage, withIntermediateDirectories: true, attributes: nil)
        
        let dbConfig = DatabaseConfig.sqlite(config: .init(path: bdkStorage.appendingPathComponent("db.sqlite").path))
        
        try await ServiceQueue.background(.bdk) {
            self.wallet = try Wallet(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                network: Env.network.bdkNetwork,
                databaseConfig: dbConfig
            )
        }
        
        Logger.info("Onchain wallet created")
        
        //Clear memory
        mnemonic = ""
        passphrase = nil
    }
    
    func stop() {
        Logger.debug("Stopping on chain wallet...")
        self.wallet = nil
        Logger.info("On chain wallet stopped")
    }
    
    func wipeStorage() async throws {
        Logger.warn("Wiping on chain wallet...")
        try FileManager.default.removeItem(at: Env.bdkStorage(walletIndex: currentWalletIndex))
        Logger.info("On chain wallet wiped")
    }
    
    func getAddress() async throws -> String {
        guard let wallet else {
            throw AppError(serviceError: .onchainWalletNotInitialized)
        }
        
        return try await ServiceQueue.background(.bdk) {
            let addressInfo = try wallet.getAddress(addressIndex: .new)
            return addressInfo.address.asString()
        }
    }
    
    func sync() async throws {
        guard let wallet else {
            throw AppError(serviceError: .onchainWalletNotInitialized)
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
