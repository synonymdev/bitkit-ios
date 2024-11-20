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
    @Published var activityItems: [PaymentDetails]? = nil // This will eventually hold other activity types
    @Published var latestActivityItems: [PaymentDetails]? = nil
    @Published var latestLightningActivityItems: [PaymentDetails]? = nil
    @Published var latestOnchainActivityItems: [PaymentDetails]? = nil
    @AppStorage("totalBalanceSats") var totalBalanceSats: Int = 0 // Combined onchain and LN
    @AppStorage("totalOnchainSats") var totalOnchainSats: Int = 0 // Combined onchain
    @AppStorage("totalLightningSats") var totalLightningSats: Int = 0 // Combined LN

    // Receiving
    @AppStorage("onchainAddress") var onchainAddress = ""
    @AppStorage("bolt11") var bolt11 = ""
    @AppStorage("bip21") var bip21 = ""

    @Published var nodeLifecycleState: NodeLifecycleState = .stopped
    @Published var nodeStatus: NodeStatus?
    @Published var nodeId: String?
    @Published var balanceDetails: BalanceDetails?
    @Published var peers: [PeerDetails]?
    @Published var channels: [ChannelDetails]?
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
        
        startPolling()
        
        syncState()
        
        Task { @MainActor in
            try await refreshBip21()
        }
        
        // Always sync on start but don't need to wait for this
        Task { @MainActor in
            try await sync()
        }
    }
    
    func stopLightningNode() async throws {
        nodeLifecycleState = .stopping
        stopPolling()
        try await LightningService.shared.stop()
        nodeLifecycleState = .stopped
        syncState()
    }
    
    func wipeLightningWallet() async throws {
        if nodeLifecycleState == .starting || nodeLifecycleState == .running {
            try await stopLightningNode()
        }
        
        // Reset AppStorage display values
        totalBalanceSats = 0
        totalOnchainSats = 0
        totalLightningSats = 0
        
        onchainAddress = ""
        bolt11 = ""
        bip21 = ""
        
        // TODO: reset display address
        
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
    
    func closeChannel(_ channel: ChannelDetails) async throws {
        try await LightningService.shared.closeChannel(userChannelId: channel.userChannelId, counterpartyNodeId: channel.counterpartyNodeId)
        syncState()
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
        
        if var payments = LightningService.shared.payments {
            payments.sort { $0.latestUpdateTimestamp > $1.latestUpdateTimestamp }
            
            // TODO: eventually load other activity types from local storage / sqlite
            var allActivity: [PaymentDetails] = []
            var latestLightningActivity: [PaymentDetails] = []
            var latestOnchainActivity: [PaymentDetails] = []
            
            payments.forEach { details in
                switch details.kind {
                case .onchain:
                    allActivity.append(details)
                    latestOnchainActivity.append(details)
                case .bolt11(hash: let hash, preimage: let preimage, secret: let secret):
                    if !(details.status == .pending && details.direction == .inbound) {
                        allActivity.append(details)
                        latestLightningActivity.append(details)
                    }
                case .bolt11Jit(hash: let hash, preimage: let preimage, secret: let secret, lspFeeLimits: let lspFeeLimits):
                    break
                case .bolt12Offer(hash: let hash, preimage: let preimage, secret: let secret, offerId: let offerId, payerNote: let payerNote, quantity: let quantity):
                    break
                case .bolt12Refund(hash: let hash, preimage: let preimage, secret: let secret, payerNote: let payerNote, quantity: let quantity):
                    break
                case .spontaneous(hash: let hash, preimage: let preimage):
                    break
                }
            }
            
            // TODO: append activity items from lightning balances
            
            let limitLatest = 3
            activityItems = allActivity
            latestActivityItems = Array(allActivity.prefix(limitLatest))
            latestLightningActivityItems = Array(latestLightningActivity.prefix(limitLatest))
            latestOnchainActivityItems = Array(latestOnchainActivity.prefix(limitLatest))
        }
    }
    
    var incomingLightningCapacitySats: UInt64? {
        guard let channels else {
            return nil
        }
        
        var capacity: UInt64 = 0
        channels.forEach { channel in
            capacity += channel.inboundCapacityMsat / 1000
        }
        return capacity
    }
    
    func refreshBip21() async throws {
        if onchainAddress.isEmpty {
            onchainAddress = try await LightningService.shared.newAddress()
        } else {
            // TODO: check if onchain has been used and generate new on if it has
        }
        
        bip21 = "bitcoin:\(onchainAddress)"
        
        if !bolt11.isEmpty {
            bip21 += "?lightning=\(bolt11)"
        }
        
        // TODO: check current bolt11 for expiry and/or if it's been used
        
        if channels?.count ?? 0 > 0 && incomingLightningCapacitySats ?? 0 > 0 {
            // Append lightning invoice if we have incoming capacity
            bolt11 = try await LightningService.shared.receive(description: "Bitkit")
            
            bip21 = "bitcoin:\(onchainAddress)?lightning=\(bolt11)"
        }
    }
    
    private func startPolling() {
        stopPolling()
        
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.nodeLifecycleState == .running {
                    self.syncState()
                }
            }
        }
    }
    
    private func stopPolling() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}
