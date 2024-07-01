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
    
    private init() {
        
    }
    
    func setup() throws {
        //TODO share with app group for background extension
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return //TODO throw error
        }
        
        print(documentsDirectory)
        
        let storageDirPath = documentsDirectory.appendingPathComponent("ldk").path //TODO add network and maybe hash mnemonic
        
        var config = defaultConfig()
        config.storageDirPath = storageDirPath
        config.logDirPath = storageDirPath
        config.network = .regtest
        config.logLevel = .trace

        let nodeBuilder = Builder.fromConfig(config: config)

        //cargo run --release --bin electrs -- -vvv --jsonrpc-import --daemon-rpc-addr 127.0.0.1:18443 --cookie polaruser:polarpass
        nodeBuilder.setEsploraServer(esploraServerUrl: "https://jaybird-logical-sadly.ngrok-free.app") //TODO get from ENV
            
//        nodeBuilder.setEsploraServer(esploraServerUrl: "http://localhost:3000") //TODO get from ENV
//        nodeBuilder.setGossipSourceRgs(rgsServerUrl: "https://rapidsync.lightningdevkit.org/snapshot/") //TODO get from ENV
        
        let mnemonic = "science fatigue phone inner pipe solve acquire nothing birth slow armor flip debate gorilla select settle talk badge uphold firm video vibrant banner casual" // = generateEntropyMnemonic()
               
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
