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
    
    static var shared = LightningService()
    
    private init() {}
    
    func setup(mnemonic: String, passphrase: String?) async throws {
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
        
        Logger.debug(Env.ldkStorage.path, context: "LDK storage path")

        Logger.debug("Building node...")
        
        try await ServiceQueue.background(.ldk) {
            self.node = try builder.build()
        }
        
        Logger.info("LDK node setup")
    }
    
    /// Pass onEvent when being used in the background to listen for payments, channels, closes, etc
    /// - Parameter onEvent: Triggered on any LDK node event
    func start(onEvent: ((Event) -> Void)? = nil) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        listenForEvents(onEvent: onEvent)

        Logger.debug("Starting node...")
        try await ServiceQueue.background(.ldk) {
            try node.start()
        }
        
        Logger.info("Node started")
        
        try await self.connectToTrustedPeers()
    }
    
    func stop() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        Logger.debug("Stopping node...")
        try await ServiceQueue.background(.ldk) {
            try node.stop()
        }
        Logger.info("Node stopped")
    }
    
    private func connectToTrustedPeers() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        try await ServiceQueue.background(.ldk) {
            for peer in Env.trustedLnPeers {
                do {
                    try node.connect(nodeId: peer.nodeId, address: peer.address, persist: true)
                    Logger.info("Connected to trusted peer: \(peer.nodeId)")
                } catch {
                    Logger.error(error, context: "Peer: \(peer.nodeId)")
                }
            }
        }
    }
    
    /// Temp fix for regtest where nodes might not agree on current fee rates
    private func setMaxDustHtlcExposureForCurrentChannels() throws {
        guard Env.network == .regtest else {
            Logger.debug("Not updating channel config for non-regtest network")
            return
        }
        
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        for channel in node.listChannels() {
            let config = channel.config
            config.setMaxDustHtlcExposureFromFixedLimit(limitMsat: 999999 * 1000)
            try? node.updateChannelConfig(userChannelId: channel.userChannelId, counterpartyNodeId: channel.counterpartyNodeId, channelConfig: config)
            Logger.info("Updated channel config for: \(channel.userChannelId)")
        }
    }
    
    func sync() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        Logger.debug("Syncing LDK...")
        try await ServiceQueue.background(.ldk) {
            try node.syncWallets()
            try? self.setMaxDustHtlcExposureForCurrentChannels()
        }
        Logger.info("LDK synced")
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
    func listenForEvents(onEvent: ((Event) -> Void)? = nil) {
        Task {
            while true {
                guard let node = self.node else {
                    Logger.error("LDK node not started")
                    return
                }
                
                let event = await node.nextEventAsync()
                onEvent?(event)
                
                //TODO actual event handler
                switch event {
                case .paymentSuccessful(paymentId: let paymentId, paymentHash: let paymentHash, feePaidMsat: let feePaidMsat):
                    Logger.info("✅ Payment successful: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) feePaidMsat: \(feePaidMsat ?? 0)")
                    break
                case .paymentFailed(paymentId: let paymentId, paymentHash: let paymentHash, reason: let reason):
                    Logger.info("❌ Payment failed: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) reason: \(reason.debugDescription)")
                    break
                case .paymentReceived(paymentId: let paymentId, paymentHash: let paymentHash, amountMsat: let amountMsat):
                    Logger.info("🤑 Payment received: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) amountMsat: \(amountMsat)")
                    break
                case .paymentClaimable(paymentId: let paymentId, paymentHash: let paymentHash, claimableAmountMsat: let claimableAmountMsat, claimDeadline: let claimDeadline):
                    Logger.info("🫰 Payment claimable: paymentId: \(paymentId) paymentHash: \(paymentHash) claimableAmountMsat: \(claimableAmountMsat)")
                    break
                case .channelPending(channelId: let channelId, userChannelId: let userChannelId, formerTemporaryChannelId: let formerTemporaryChannelId, counterpartyNodeId: let counterpartyNodeId, fundingTxo: let fundingTxo):
                    Logger.info("⏳ Channel pending: channelId: \(channelId) userChannelId: \(userChannelId) formerTemporaryChannelId: \(formerTemporaryChannelId) counterpartyNodeId: \(counterpartyNodeId) fundingTxo: \(fundingTxo)")
                    break
                case .channelReady(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId):
                    Logger.info("👐 Channel ready: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?")")
                    break
                case .channelClosed(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId, reason: let reason):
                    Logger.info("⛔ Channel closed: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?") reason: \(reason.debugDescription)")
                    break
                }
                
                node.eventHandled()
            }
        }
    }
}
