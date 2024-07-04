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
        config.anchorChannelsConfig = .init(
            trustedPeersNoReserve: Env.trustedLnPeers.map({ $0.nodeId }),
            perChannelReserveSats: 2000 //TODO set correctly
        )
        
        let nodeBuilder = Builder.fromConfig(config: config)
        nodeBuilder.setEsploraServer(esploraServerUrl: Env.esploraServerUrl)
        
        if let rgsServerUrl = Env.ldkRgsServerUrl {
            nodeBuilder.setGossipSourceRgs(rgsServerUrl: rgsServerUrl)
        }
        
        nodeBuilder.setEntropyBip39Mnemonic(mnemonic: mnemonic, passphrase: nil)
        
        node = try nodeBuilder.build()
        print("LDK node setup")
    }
    
    func start() async throws {
        guard let node else {
            //TODO throw custom error
            return
        }
        
        print("Starting node...")
        try await ServiceQueue.background(.ldk) {
            try node.start()
        }
        print("Node started!")
        
        try await self.connectToTrustedPeers()
    }
    
    private func connectToTrustedPeers() async throws {
        guard let node else {
            //TODO throw custom error
            return
        }
        
        try await ServiceQueue.background(.ldk) {
            for peer in Env.trustedLnPeers {
                do {
                    try node.connect(nodeId: peer.nodeId, address: peer.address, persist: true)
                } catch {
                    //TODO log error
                    print("Error connecting to peer: \(peer.nodeId)")
                }
            }
        }
    }
    
    func sync() async throws {
        guard let node else {
            //TODO throw custom error
            return
        }
        
        print("Syncing LDK...")
        try await ServiceQueue.background(.ldk) {
            try node.syncWallets()
        }
        print("LDK synced")
    }
}

//MARK: UI Helpers (Published via LightningViewModel)
extension LightningService {
    var nodeId: String? { node?.nodeId() }
    var balances: BalanceDetails? { node?.listBalances() }
    var status: NodeStatus? { node?.status() }
    var peers: [PeerDetails]? { node?.listPeers() }
    var Channels: [ChannelDetails]? { node?.listChannels() }
    var payments: [PaymentDetails]? {  node?.listPayments() }
}
