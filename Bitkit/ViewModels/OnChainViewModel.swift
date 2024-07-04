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
    
    func start() async throws {
        let mnemonic = "science fatigue phone inner pipe solve acquire nothing birth slow armor flip debate gorilla select settle talk badge uphold firm video vibrant banner casual" // = generateEntropyMnemonic()
        let passphrase: String? = nil
        
        try OnChainService.shared.setup()
        try OnChainService.shared.createWallet(mnemonic: mnemonic, passphrase: passphrase)
        syncState()
    }
    
    func newReceiveAddress() throws {
        address = try OnChainService.shared.getAddress()
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
