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
    private var hasSynced = false
    
    private var esploraClient: EsploraClient {
        EsploraClient(url: Env.esploraServerUrl)
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
                
        Logger.debug("Creating onchain wallet...")
        
        let bdkStorage = Env.bdkStorage(walletIndex: walletIndex)
        try FileManager.default.createDirectory(at: bdkStorage, withIntermediateDirectories: true, attributes: nil)
        let sqlitePath = bdkStorage.appendingPathComponent("db.sqlite").path
                
        try await ServiceQueue.background(.bdk) {
            self.wallet = try Wallet(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                persistenceBackendPath: sqlitePath,
                network: Env.network.bdkNetwork
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
    
    func wipeStorage(walletIndex: Int) async throws {
        guard wallet == nil else {
            throw AppError(serviceError: .onchainWalletStillRunning)
        }

        let directory = Env.bdkStorage(walletIndex: walletIndex)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            Logger.warn("No directory found to wipe: \(directory.path)")
            return
        }
        
        Logger.warn("Wiping on chain wallet...")
        try FileManager.default.removeItem(at: directory)
        Logger.info("On chain wallet wiped")
    }
    
    func getAddress() async throws -> String {
        guard let wallet else {
            throw AppError(serviceError: .onchainWalletNotInitialized)
        }
        
        return try await ServiceQueue.background(.bdk) {
            let addressInfo = try wallet.revealNextAddress(keychain: .external)
            return addressInfo.address.asString()
        }
    }
    
    /// Partial sync. Collects all revealed script pubkeys from the wallet keychain.
    func syncWithRevealedSpks() async throws {
        guard let wallet else {
            throw AppError(serviceError: .onchainWalletNotInitialized)
        }
        
        Logger.debug("Syncing BDK...")
                
        try await ServiceQueue.background(.bdk) {
            let request = wallet.startSyncWithRevealedSpks()
            let update = try self.esploraClient.sync(syncRequest: request, parallelRequests: 5)
            try wallet.applyUpdate(update: update)
            
            //TODO: persist wallet??
        }
        
        hasSynced = true
        
        Logger.info("BDK synced")
    }
    
    /// Required on restore or manually from settings. Performs a full scan of the wallet.
    func fullScan() async throws {
        guard let wallet else {
            throw AppError(serviceError: .onchainWalletNotInitialized)
        }
        
        Logger.debug("Full on chain scan...")
                
        try await ServiceQueue.background(.bdk) {
            let request = wallet.startFullScan()
            let update = try self.esploraClient.fullScan(
                fullScanRequest: request,
                stopGap: Env.onchainWalletStopGap, 
                parallelRequests: Env.esploraParallelRequests
            )
            try wallet.applyUpdate(update: update)
            //TODO: persist wallet once BDK is updated to beta release
        }
        
        hasSynced = true
        
        Logger.info("Full scan complete")
    }
}

//MARK: UI Helpers (Published via OnChainViewModel)
extension OnChainService {
    //TODO catch errors?
    var balance: Balance? { hasSynced ? wallet?.getBalance() : nil }
}
