//
//  WalletViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import LDKNode
import SwiftUI

@MainActor
class WalletViewModel: ObservableObject {
    @Published var walletExists: Bool? = nil
    @Published var isSyncingWallet = false // Syncing both LN and on chain
    @Published var bip21: String? = nil
    @Published var activityItems: [PaymentDetails]? = nil // This will eventually hold other activity types
    @AppStorage("totalBalanceSats") var totalBalanceSats: Int = 0 // Combined onchain and LN
    @AppStorage("totalOnchainSats") var totalOnchainSats: Int = 0 // Combined onchain
    @AppStorage("totalLightningSats") var totalLightningSats: Int = 0 // Combined LN
    @Published var nodeLifecycleState: NodeLifecycleState = .stopped
    @Published var nodeStatus: NodeStatus?
    @Published var nodeId: String?
    @Published var balanceDetails: BalanceDetails?
    @Published var peers: [PeerDetails]?
    @Published var channels: [ChannelDetails]?
    @Published var onchainAddress: String? = nil
    private var onEvent: ((Event) -> Void)? = nil // Optional event handler for UI updates
    private var syncTimer: Timer?

    func setWalletExistsState() throws {
        walletExists = try Keychain.exists(key: .bip39Mnemonic(index: 0))
    }
    
    func setOnEvent(_ onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }
    
    func start(walletIndex: Int = 0) async throws {
        nodeLifecycleState = .starting
        syncState()
        do {
            try await LightningService.shared.setup(walletIndex: walletIndex)
            try await LightningService.shared.start(onEvent: { event in
                // On every lightning event just sync UI
                Task { @MainActor in
                    self.syncState()
                    self.onEvent?(event)
                }
            })
        } catch {
            nodeLifecycleState = .errorStarting(cause: error)
            throw error
        }
        
        nodeLifecycleState = .running
        
        syncState()
        
        // Always sync on start but don't need to wait for this
        Task { @MainActor in
            try await sync()
        }
    }
    
    func stopLightningNode() async throws {
        nodeLifecycleState = .stopping
        try await LightningService.shared.stop()
        nodeLifecycleState = .stopped
        syncState()
    }
    
    func wipeLightningWallet() async throws {
        if nodeLifecycleState == .starting || nodeLifecycleState == .running {
            try await stopLightningNode()
        }
        
        try await LightningService.shared.wipeStorage(walletIndex: 0)
    }
    
    func createInvoice(amountSats: UInt64, description: String, expirySecs: UInt32) async throws -> String {
        try await LightningService.shared.receive(amountSats: amountSats, description: description, expirySecs: expirySecs)
    }
    
    func sync() async throws {
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
            try await LightningService.shared.sync()
        } catch {
            isSyncingWallet = false
            throw error
        }

        isSyncingWallet = false
        syncState()
    }
    
    func send(address: String, sats: UInt64) async throws -> Txid {
        let txid = try await LightningService.shared.send(address: address, sats: sats)
        Task {
            // Best to auto sync on chain so we have latest state
            try await sync()
        }
        return txid
    }
    
    func send(bolt11: String, sats: UInt64? = nil) async throws -> PaymentHash {
        let hash = try await LightningService.shared.send(bolt11: bolt11, sats: sats)
        syncState()
        return hash
    }
    
    internal func syncState() {
        nodeStatus = LightningService.shared.status
        nodeId = LightningService.shared.nodeId
        balanceDetails = LightningService.shared.balances
        peers = LightningService.shared.peers
        channels = LightningService.shared.channels
        
        if let balanceDetails {
            totalOnchainSats = Int(balanceDetails.totalOnchainBalanceSats)
            totalLightningSats = Int(balanceDetails.totalLightningBalanceSats)
            totalBalanceSats = Int(balanceDetails.totalLightningBalanceSats + balanceDetails.totalOnchainBalanceSats)
        }
                
        // TODO: eventually load other activity types from local storage
        activityItems = (LightningService.shared.payments ?? []).reversed().filter { details in
            switch details.kind {
            case .onchain:
                return true
            case .bolt11(hash: let hash, preimage: let preimage, secret: let secret):
                return !(details.status == .pending && details.direction == .inbound)
            case .bolt11Jit(hash: let hash, preimage: let preimage, secret: let secret, lspFeeLimits: let lspFeeLimits):
                return false
            case .bolt12Offer(hash: let hash, preimage: let preimage, secret: let secret, offerId: let offerId):
                return false
            case .bolt12Refund(hash: let hash, preimage: let preimage, secret: let secret):
                return false
            case .spontaneous(hash: let hash, preimage: let preimage):
                return true
            }
        }
    }
    
    // TODO: create LN invoice as well
    func createBip21() async throws {
        let address = try await LightningService.shared.newAddress()
        bip21 = "bitcoin:\(address)"
    }
}
