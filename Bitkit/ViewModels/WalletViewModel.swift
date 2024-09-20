//
//  WalletViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import BitcoinDevKit
import LDKNode
import SwiftUI

@MainActor
class WalletViewModel: ObservableObject {
    // MARK: General state
    @Published var walletExists: Bool? = nil
    @Published var isSyncingWallet = false // Syncing both LN and on chain
    @Published var walletBalanceSats: UInt64? = nil // Combined onchain and LN
    @Published var bip21: String? = nil
    @Published var activityItems: [ActivityItem]? = nil
    
    // MARK: Lightning state
    @Published var lightningState: LightningNodeState = .stopped
    @Published var lightningStatus: NodeStatus?
    @Published var lightningNodeId: String?
    @Published var lightningBalance: BalanceDetails?
    @Published var lightningPeers: [PeerDetails]?
    @Published var lightningChannels: [ChannelDetails]?
    
    // MARK: Onchain state
    @Published var onchainBalance: Balance?
    @Published var onchainAddress: String?
    
    func startAll() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.startOnchain()
            }
            
            group.addTask {
                try await self.startLightning()
            }
            
            try await group.waitForAll()
        }
    }
    
    func setWalletExistsState() throws {
        walletExists = try Keychain.exists(key: .bip39Mnemonic(index: 0))
    }
    
    func sync(fullOnchainScan: Bool = false) async throws {
        syncState()
        
        if isSyncingWallet {
            Logger.warn("Sync already in progress, waiting for existing sync.")
            while isSyncingWallet {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            return
        }
        
        isSyncingWallet = true
        syncState()
        
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    if fullOnchainScan {
                        try await OnChainService.shared.fullScan()
                    } else {
                        try await OnChainService.shared.syncWithRevealedSpks()
                    }
                }
                if lightningState == .running {
                    group.addTask {
                        try await LightningService.shared.sync()
                    }
                } else {
                    // Not really required to throw an error here
                    Logger.warn("Can't sync lightning when node is not running. Current state: \(lightningState.rawValue)")
                }
                
                try await group.waitForAll()
            }
            
        } catch {
            isSyncingWallet = false
            throw error
        }

        isSyncingWallet = false
        syncState()
    }
    
    internal func syncState() {
        // MARK: Lightning
        lightningStatus = LightningService.shared.status
        lightningNodeId = LightningService.shared.nodeId
        lightningBalance = LightningService.shared.balances
        lightningPeers = LightningService.shared.peers
        lightningChannels = LightningService.shared.channels
        
        // MARK: onchain
        onchainBalance = OnChainService.shared.balance
        
        // MARK: combined
        if let onchainBalance, let lightningBalance {
            walletBalanceSats = lightningBalance.totalLightningBalanceSats + onchainBalance.total.toSat()
        }
        
        var newActivityItems: [ActivityItem] = []
        
        // TODO: tx history
        if let lnTxs = LightningService.shared.payments {
            newActivityItems.append(contentsOf: lnTxs.map { .lightning(.init(payment: $0)) })
        }
        
        if let onchainTxs = OnChainService.shared.transactions {
            newActivityItems.append(contentsOf: onchainTxs.map { .onchain(.init(tx: $0)) })
        }
        
        activityItems = newActivityItems // TODO: sort
    }
    
    func createBip21() async throws {
        // TODO: actually implement BIP21 spec
        if onchainAddress == nil {
            try await newOnchainReceiveAddress()
        }
        
        guard let onchainAddress else {
            Logger.error("Missing on chain address, cannot create bip21 string")
            return
        }
        
        bip21 = "bitcoin:\(onchainAddress)"
    }
}
