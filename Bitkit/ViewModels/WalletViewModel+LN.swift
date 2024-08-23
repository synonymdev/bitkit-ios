//
//  WalletViewModel+LN.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import LDKNode
import SwiftUI

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
}
