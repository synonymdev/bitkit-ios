//
//  OnChainViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import SwiftUI
import BitcoinDevKit

@MainActor
class OnChainViewModel: ObservableObject {
    @Published var isSyncing = false
    @Published var balance: Balance?
    @Published var address: String?
    
    private init() {}
    public static var shared = OnChainViewModel()

    func start(walletIndex: Int = 0) async throws {
        try await OnChainService.shared.setup(walletIndex: walletIndex)
        syncState()
        
        //Always sync on start but don't need to wait for this
        Task { @MainActor in
            try await sync()
        }
    }
    
    func stop() throws {
        OnChainService.shared.stop()
        syncState()
    }
    
    func wipeWallet() async throws {
        try stop()
        try await OnChainService.shared.wipeStorage(walletIndex: 0)
    }
    
    func newReceiveAddress() async throws {
        address = try await OnChainService.shared.getAddress()
    }
    
    func sync() async throws {
        isSyncing = true
        syncState()
        do {
            try await OnChainService.shared.sync()
            isSyncing = false
            syncState()
        } catch {
            isSyncing = false
            syncState()
            throw error
        }
    }
    
    private func syncState() {
        balance = OnChainService.shared.balance
    }
}
