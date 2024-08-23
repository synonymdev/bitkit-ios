//
//  WalletViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import BitcoinDevKit
import LDKNode
import SwiftUI

enum LightningNodeState {
    case stopped
    case starting
    case running
    case stopping
    
    var debugState: String {
        switch self {
        case .stopped:
            return "Stopped 🛑"
        case .starting:
            return "Starting... 🚀"
        case .running:
            return "Running ✅"
        case .stopping:
            return "Stopping... 🛑"
        }
    }
}

extension NodeStatus {
    var debugState: String {
        var debug = """
        Running: \(isRunning ? "✅" : "❌")
        Current best block \(currentBestBlock.height)
        """
        
        if let latestWalletSyncTimestamp {
            debug += "\nLast synced \(Date(timeIntervalSince1970: TimeInterval(latestWalletSyncTimestamp)).description)\n"
        } else {
            debug += "\nLast synced never\n"
        }
        
        return debug
    }
}

@MainActor
class WalletViewModel: ObservableObject {
    // MARK: General state
    @Published var walletExists: Bool? = nil
    @Published var isSyncingWallet = false // Syncing both LN and on chain
    @Published var walletBalanceSats: UInt64? = nil // Combined onchain and LN
    @Published var bip21: String? = nil
    
    // MARK: Lightning state
    @Published var lightningState: LightningNodeState = .stopped
    @Published var lightningStatus: NodeStatus?
    @Published var lightningNodeId: String?
    @Published var lightningBalance: BalanceDetails?
    @Published var lightningPeers: [PeerDetails]?
    @Published var lightningChannels: [ChannelDetails]?
    @Published var lightningPayments: [PaymentDetails]? // TODO: unify with onchain
    
    // MARK: Onchain state
    @Published var onchainBalance: Balance?
    @Published var onchainAddress: String?
    
    private init() {}
    public static var shared = WalletViewModel()
    
    func setWalletExistsState() {
        do {
            walletExists = try Keychain.exists(key: .bip39Mnemonic(index: 0))
        } catch {
            // TODO: show error
            Logger.error(error)
        }
    }
    
    func sync(fullOnchainScan: Bool = false) async throws {
        syncState()
        
        if isSyncingWallet {
            while isSyncingWallet {
                Logger.warn("Sync already in progress, waiting for existing sync.")
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
                    Logger.warn("Can't sync lightning when node is not running. Current state: \(lightningState.debugState)")
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
        lightningPayments = LightningService.shared.payments
        
        // MARK: onchain
        onchainBalance = OnChainService.shared.balance
        
        // MARK: combined
        if let onchainBalance, let lightningBalance {
            walletBalanceSats = lightningBalance.totalLightningBalanceSats + onchainBalance.total.toSat()
        } else {
            Logger.warn("Failed to calculate wallet balance, onchain: \(String(describing: onchainBalance)), lightning: \(String(describing: lightningBalance))")
        }
        // TODO: tx history
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
