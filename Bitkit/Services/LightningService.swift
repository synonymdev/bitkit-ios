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
        config.network = .regtest
        config.logLevel = .trace
        
        let nodeBuilder = Builder.fromConfig(config: config)
        nodeBuilder.setEsploraServer(esploraServerUrl: Env.esploraServerUrl)
        
        if let rgsServerUrl = Env.ldkRgsServerUrl {
            nodeBuilder.setGossipSourceRgs(rgsServerUrl: rgsServerUrl)
        }
        
        nodeBuilder.setEntropyBip39Mnemonic(mnemonic: mnemonic, passphrase: nil)
        
        node = try nodeBuilder.build()
    }
    
    func start() throws {
        guard let node else {
            //TODO throw custom error
            return
        }
        try node.start()
    }
    
    func sync() throws {
        guard let node else {
            //TODO throw custom error
            return
        }
        try node.syncWallets()
    }
}

//MARK: UI Helpers (Published via LightningViewModel)
extension LightningService {
    var nodeId: String? { node?.nodeId() }
    var balances: BalanceDetails? { node?.listBalances() }
    var status: NodeStatus? { node?.status() }
    var listPeers: [PeerDetails]? { node?.listPeers() }
    var listChannels: [ChannelDetails]? { node?.listChannels() }
    var listPayments: [PaymentDetails]? {  node?.listPayments() }
}
