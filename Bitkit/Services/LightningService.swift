//
//  LightningService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import Foundation
import LDKNode

// TODO: catch all errors and pass a readable error message to the UI

class LightningService {
    private var node: Node?
    var currentWalletIndex: Int = 0
    
    static var shared = LightningService()
    
    private init() {}
    
    func setup(walletIndex: Int) async throws {
        Logger.debug("Checking lightning process lock...")
        try StateLocker.lock(.lightning, wait: 30) // Wait 30 seconds to lock because maybe extension is still running
        
        guard var mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw CustomServiceError.mnemonicNotFound
        }
        
        var passphrase = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        
        currentWalletIndex = walletIndex
        
        var config = defaultConfig()
        let ldkStoragePath = Env.ldkStorage(walletIndex: walletIndex).path
        config.storageDirPath = ldkStoragePath
        config.logDirPath = ldkStoragePath
        config.network = Env.network
        config.logLevel = .trace
        
        Logger.debug("Using LDK storage path: \(ldkStoragePath)")
        
        config.trustedPeers0conf = Env.trustedLnPeers.map { $0.nodeId }
        config.anchorChannelsConfig = .init(
            trustedPeersNoReserve: Env.trustedLnPeers.map { $0.nodeId },
            perChannelReserveSats: 1000 // TODO: set correctly
        )
        
        let builder = Builder.fromConfig(config: config)
        builder.setEsploraServer(esploraServerUrl: Env.esploraServerUrl)
        
        if let rgsServerUrl = Env.ldkRgsServerUrl {
            builder.setGossipSourceRgs(rgsServerUrl: rgsServerUrl)
        } else {
            builder.setGossipSourceP2p()
        }
        
        builder.setEntropyBip39Mnemonic(mnemonic: mnemonic, passphrase: passphrase)
        
        Logger.debug(ldkStoragePath, context: "LDK storage path")
        
        Logger.debug("Building node...")
        
        try await ServiceQueue.background(.ldk) {
            self.node = try builder.build()
        }
        
        Logger.info("LDK node setup")
        
        // Clear memory
        mnemonic = ""
        passphrase = nil
    }
    
    /// Pass onEvent when being used in the background to listen for payments, channels, closes, etc
    /// - Parameter onEvent: Triggered on any LDK node event
    func start(onEvent: ((Event) -> Void)? = nil) async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        listenForEvents(onEvent: onEvent)
        
        Logger.debug("Starting node...")
        try await ServiceQueue.background(.ldk) {
            try node.start()
        }
        
        Logger.info("Node started")
        
        try await connectToTrustedPeers()
    }
    
    func stop() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        Logger.debug("Stopping node...")
        try await ServiceQueue.background(.ldk) {
            try node.stop()
            self.node = nil
        }
        Logger.info("Node stopped")
        
        try StateLocker.unlock(.lightning)
    }
    
    func wipeStorage(walletIndex: Int) async throws {
        guard node == nil else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        let directory = Env.ldkStorage(walletIndex: walletIndex)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            Logger.warn("No directory found to wipe: \(directory.path)")
            return
        }
        
        Logger.warn("Wiping on lighting wallet...")
        try FileManager.default.removeItem(at: directory)
        Logger.info("Lightning wallet wiped")
    }
    
    private func connectToTrustedPeers() async throws {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
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
            throw AppError(serviceError: .nodeNotSetup)
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
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        Logger.debug("Syncing LDK...")
        try await ServiceQueue.background(.ldk) {
            try node.syncWallets()
            try? self.setMaxDustHtlcExposureForCurrentChannels()
        }
        Logger.info("LDK synced")
    }
    
    func newAddress() async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().newAddress()
        }
    }
    
    func receive(amountSats: UInt64, description: String, expirySecs: UInt32 = 3600) async throws -> Bolt11Invoice {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        return try await ServiceQueue.background(.ldk) {
            try node
                .bolt11Payment()
                .receive(
                    amountMsat: amountSats * 1000,
                    description: description,
                    expirySecs: expirySecs
                )
        }
    }
    
    func send(address: String, sats: UInt64) async throws -> Txid {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        Logger.info("Sending \(sats) sats to \(address)")
        
        return try await ServiceQueue.background(.ldk) {
            try node.onchainPayment().sendToAddress(address: address, amountMsat: sats)
        }
    }
    
    func send(bolt11: Bolt11Invoice, sats: UInt64? = nil) async throws -> PaymentHash {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        Logger.info("Paying bolt11: \(bolt11)")
        
        return try await ServiceQueue.background(.ldk) {
            if let sats {
                try node.bolt11Payment().sendUsingAmount(invoice: bolt11, amountMsat: sats * 1000)
            } else {
                try node.bolt11Payment().send(invoice: bolt11)
            }
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
    
    func sign(message: String) async throws -> String {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        guard let msg = message.data(using: .utf8) else {
            throw AppError(serviceError: .invalidNodeSigningMessage)
        }
        
        return try await ServiceQueue.background(.ldk) {
            try node.signMessage(msg: [UInt8](msg))
        }
    }
    
    func openChannel(peer: LnPeer, channelAmountSats: UInt64, pushToCounterpartySats: UInt64? = nil) async throws -> UserChannelId {
        guard let node else {
            throw AppError(serviceError: .nodeNotSetup)
        }
        
        return try await ServiceQueue.background(.ldk) {
            try node.connectOpenChannel(
                nodeId: peer.nodeId,
                address: peer.address,
                channelAmountSats: channelAmountSats,
                pushToCounterpartyMsat: pushToCounterpartySats == nil ? nil : pushToCounterpartySats! * 1000,
                channelConfig: nil,
                announceChannel: false
            )
        }
    }
}

// MARK: UI Helpers (Published via WalletViewModel)

extension LightningService {
    var nodeId: String? { node?.nodeId() }
    var balances: BalanceDetails? { node?.listBalances() }
    var status: NodeStatus? { node?.status() }
    var peers: [PeerDetails]? { node?.listPeers() }
    var channels: [ChannelDetails]? { node?.listChannels() }
    var payments: [PaymentDetails]? { node?.listPayments() }
}

// MARK: Events

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
                
                // TODO: actual event handler
                switch event {
                case .paymentSuccessful(paymentId: let paymentId, paymentHash: let paymentHash, feePaidMsat: let feePaidMsat):
                    Logger.info("✅ Payment successful: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) feePaidMsat: \(feePaidMsat ?? 0)")
                case .paymentFailed(paymentId: let paymentId, paymentHash: let paymentHash, reason: let reason):
                    Logger.info("❌ Payment failed: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) reason: \(reason.debugDescription)")
                case .paymentReceived(paymentId: let paymentId, paymentHash: let paymentHash, amountMsat: let amountMsat):
                    Logger.info("🤑 Payment received: paymentId: \(paymentId ?? "?") paymentHash: \(paymentHash) amountMsat: \(amountMsat)")
                case .paymentClaimable(paymentId: let paymentId, paymentHash: let paymentHash, claimableAmountMsat: let claimableAmountMsat, claimDeadline: let claimDeadline):
                    Logger.info("🫰 Payment claimable: paymentId: \(paymentId) paymentHash: \(paymentHash) claimableAmountMsat: \(claimableAmountMsat)")
                case .channelPending(channelId: let channelId, userChannelId: let userChannelId, formerTemporaryChannelId: let formerTemporaryChannelId, counterpartyNodeId: let counterpartyNodeId, fundingTxo: let fundingTxo):
                    Logger.info("⏳ Channel pending: channelId: \(channelId) userChannelId: \(userChannelId) formerTemporaryChannelId: \(formerTemporaryChannelId) counterpartyNodeId: \(counterpartyNodeId) fundingTxo: \(fundingTxo)")
                case .channelReady(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId):
                    Logger.info("👐 Channel ready: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?")")
                case .channelClosed(channelId: let channelId, userChannelId: let userChannelId, counterpartyNodeId: let counterpartyNodeId, reason: let reason):
                    Logger.info("⛔ Channel closed: channelId: \(channelId) userChannelId: \(userChannelId) counterpartyNodeId: \(counterpartyNodeId ?? "?") reason: \(reason.debugDescription)")
                }
                
                node.eventHandled()
            }
        }
    }
}
