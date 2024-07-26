//
//  LightningViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import SwiftUI
import LDKNode

@MainActor
class LightningViewModel: ObservableObject {
    @Published var isSyncing = false
    @Published var status: NodeStatus?
    @Published var nodeId: String?
    @Published var balance: BalanceDetails?
    @Published var peers: [PeerDetails]?
    @Published var channels: [ChannelDetails]?
    @Published var payments: [PaymentDetails]?
    
    func start() async throws {
        let mnemonic = Env.testMnemonic // = generateEntropyMnemonic()
        let passphrase: String? = nil
        
        syncState()
        try await LightningService.shared.setup(mnemonic: mnemonic, passphrase: passphrase)
        try await LightningService.shared.start(onEvent: { _ in
            Task { @MainActor in
                self.syncState()
            }
        })
        syncState()
        
        //TODO listen on LDK events to sync UI state
    }
    
    func stop() async throws {
        try await LightningService.shared.stop()
        syncState()
    }
    
    func sync() async throws {
        isSyncing = true
        syncState()
    
        do {
            try await LightningService.shared.sync()
            isSyncing = false
        } catch {
            isSyncing = false
            throw error
        }
        
        syncState()
    }
    
    private func syncState() {
        status = LightningService.shared.status
        nodeId = LightningService.shared.nodeId
        balance = LightningService.shared.balances
        peers = LightningService.shared.peers
        channels = LightningService.shared.channels
        payments = LightningService.shared.payments
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
