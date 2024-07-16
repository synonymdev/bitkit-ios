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
        let mnemonic = "always coconut smooth scatter steel web version exist broken motion damage board trap dinosaur include alone dust flag paddle give divert journey garden bench" // = generateEntropyMnemonic()
        let passphrase: String? = nil
        
        try OnChainService.shared.setup()
        try await OnChainService.shared.createWallet(mnemonic: mnemonic, passphrase: passphrase)
        syncState()
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
