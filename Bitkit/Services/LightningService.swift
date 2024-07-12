//
//  LightningService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import Foundation
import LDKNode

//TODO catch all errors and pass a readable error message to the UI

class LightningService {
    private var node: Node?
    
    static var shared: LightningService = LightningService()
    
    private init() {}
    
    func setup(mnemonic: String, passphrase: String?) throws {
        var config = defaultConfig()
        config.storageDirPath = Env.ldkStorage.path
        config.logDirPath = Env.ldkStorage.path
        config.network = Env.network.ldkNetwork
        config.logLevel = .trace
        
        config.trustedPeers0conf = Env.trustedLnPeers.map({ $0.nodeId })
        config.anchorChannelsConfig = .init(
            trustedPeersNoReserve: Env.trustedLnPeers.map({ $0.nodeId }),
            perChannelReserveSats: 1000 //TODO set correctly
        )
        
        let builder = Builder.fromConfig(config: config)
        builder.setEsploraServer(esploraServerUrl: Env.esploraServerUrl)
        
        if let rgsServerUrl = Env.ldkRgsServerUrl {
            builder.setGossipSourceRgs(rgsServerUrl: rgsServerUrl)
        } else {
            builder.setGossipSourceP2p()
        }
        
        builder.setEntropyBip39Mnemonic(mnemonic: mnemonic, passphrase: nil)
        
        node = try builder.build()
        print("LDK node setup")
        
        print(Env.ldkStorage.path)
    }
    
    func start() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        listenForEvents()

        print("Starting node...")
        try await ServiceQueue.background(.ldk) {
            try node.start()
        }
        print("Node started!")
        
        
        try await self.connectToTrustedPeers()
    }
    
    private func connectToTrustedPeers() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        try await ServiceQueue.background(.ldk) {
            for peer in Env.trustedLnPeers {
                do {
                    try node.connect(nodeId: peer.nodeId, address: peer.address, persist: true)
                    print("Connected to trusted peer: \(peer.nodeId)")
                } catch {
                    //TODO log error
                    print("Error connecting to peer: \(peer.nodeId)")
                }
            }
        }
    }
    
    func sync() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        print("Syncing LDK...")
        try await ServiceQueue.background(.ldk) {
            try node.syncWallets()
        }
        print("LDK synced")
    }
    
    func receive(amountSats: UInt64, description: String, expirySecs: UInt32 = 3600) async throws -> Bolt11Invoice {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        return try await ServiceQueue.background(.ldk) {
            return try node
                .bolt11Payment()
                .receive(
                    amountMsat: amountSats * 1000,
                    description: description,
                    expirySecs: expirySecs
                )
        }
    }
    
    func send(bolt11: Bolt11Invoice) async throws -> PaymentHash {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        //Check if peer is connected
        
        return try await ServiceQueue.background(.ldk) {
            return try node.bolt11Payment().send(invoice: bolt11)
        }
    }
    
    func closeChannel(userChannelId: ChannelId, counterpartyNodeId: PublicKey) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        return try await ServiceQueue.background(.ldk) {
            try node.closeChannel(
                userChannelId: userChannelId,
                counterpartyNodeId: counterpartyNodeId
            )
        }
    }
}

//MARK: UI Helpers (Published via LightningViewModel)
extension LightningService {
    var nodeId: String? { node?.nodeId() }
    var balances: BalanceDetails? { node?.listBalances() }
    var status: NodeStatus? { node?.status() }
    var peers: [PeerDetails]? { node?.listPeers() }
    var channels: [ChannelDetails]? { node?.listChannels() }
    var payments: [PaymentDetails]? {  node?.listPayments() }
}

//MARK: Events
extension LightningService {
    func listenForEvents() {
        Task {
            while true {
                guard let node = self.node else {
                    print("LDK node not started")
                    return
                }
                
                let event = await node.nextEventAsync()
                
                
                //TODO actual event handler
                
                switch event {
                case .paymentSuccessful(paymentId: let paymentId, paymentHash: let paymentHash, feePaidMsat: let feePaidMsat):
                    print("✅ Payment successful: \(feePaidMsat)")
                    break
                case .paymentFailed(paymentId: let paymentId, paymentHash: let paymentHash, reason: let reason):
                    print("❌ Payment failed: \(reason.debugDescription)")
                    break
                case .paymentReceived(paymentId: let paymentId, paymentHash: let paymentHash, amountMsat: let amountMsat):
                    print("🤑 Payment received: \(amountMsat)")
                    break
                case .paymentClaimable(paymentId: let paymentId, paymentHash: let paymentHash, claimableAmountMsat: let claimableAmountMsat, claimDeadline: let claimDeadline):
                    print("🫰 Payment claimable: \(claimableAmountMsat)")
                    break
                case .channelPending(channelId: let channelId, userChannelId: let userChannelId, formerTemporaryChannelId: let formerTemporaryChannelId, counterpartyNodeId: let counterpartyNodeId, fundingTxo: let fundingTxo):
                    print("⏳ Channel pending: \(channelId)")
                    break
                case .channelReady(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId):
                    print("👐 Channel ready: \(channelId)")
                    break
                case .channelClosed(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId, reason: let reason):
                    print("⛔ Channel closed: \(channelId)")
                    break
                }
                
                node.eventHandled()
            }
        }
    }
}
