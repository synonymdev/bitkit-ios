//
//  WalletViewModel+LN.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import LDKNode
import SwiftUI

enum LightningNodeState: String {
    case stopped
    case starting
    case running
    case stopping
    
    var displayState: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .stopping:
            return "Stopping"
        }
    }
    
    var debugEmoji: String {
        switch self {
        case .stopped:
            return "❌"
        case .starting:
            return "⏳"
        case .running:
            return "⚡️"
        case .stopping:
            return "🛑"
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

extension WalletViewModel {
    func startLightning(walletIndex: Int = 0) async throws {
        lightningState = .starting
        syncState()
        try await LightningService.shared.setup(walletIndex: walletIndex)
        try await LightningService.shared.start(onEvent: { _ in
            // On every lightning event just sync UI
            Task { @MainActor in
                self.syncState()
            }
        })
        
        lightningState = .running
        
        try await OnChainService.shared.setup(walletIndex: walletIndex)
        
        syncState()
        
        // Always sync on start but don't need to wait for this
        Task { @MainActor in
            try await sync()
        }
    }
    
    func stopLightningNode() async throws {
        lightningState = .stopping
        try await LightningService.shared.stop()
        lightningState = .stopped
        syncState()
    }
    
    func wipeLightningWallet() async throws {
        try await stopLightningNode()
        try await LightningService.shared.wipeStorage(walletIndex: 0)
    }
    
    func createInvoice(amountSats: UInt64, description: String, expirySecs: UInt32) async throws -> String {
        try await LightningService.shared.receive(amountSats: amountSats, description: description, expirySecs: expirySecs)
    }
}
