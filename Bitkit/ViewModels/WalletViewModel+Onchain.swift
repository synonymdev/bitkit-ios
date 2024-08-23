//
//  WalletViewModel+Onchain.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

extension WalletViewModel {
    func startOnchain(walletIndex: Int = 0) async throws {
        try await OnChainService.shared.setup(walletIndex: walletIndex)
        syncState()
            
        // Always sync on start but don't need to wait for this
        Task { @MainActor in
            try await sync()
        }
    }
    
    func stopOnchainWallet() throws {
        OnChainService.shared.stop()
        syncState()
    }
    
    func wipeOnchainWallet() async throws {
        try stopOnchainWallet()
        try await OnChainService.shared.wipeStorage(walletIndex: 0)
    }
    
    func newOnchainReceiveAddress() async throws {
        onchainAddress = try await OnChainService.shared.getAddress()
    }
}
