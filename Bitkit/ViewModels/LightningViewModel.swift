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
    
    private init() {}
    public static var shared = LightningViewModel()

    func start(walletIndex: Int = 0) async throws {
        syncState()
        try await LightningService.shared.setup(walletIndex: walletIndex)
        try await LightningService.shared.start(onEvent: { _ in
            //On every lightning event just sync UI
            Task { @MainActor in
                self.syncState()
            }
        })
        syncState()
                
        //Always sync on start but don't need to wait for this
        Task { @MainActor in
            try await sync()
        }
    }
    
    func stop() async throws {
        try await LightningService.shared.stop()
        syncState()
    }
    
    func wipeWallet() async throws {
        try await stop()
        try await LightningService.shared.wipeStorage()
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
