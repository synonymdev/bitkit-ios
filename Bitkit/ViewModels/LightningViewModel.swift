//
//  LightningViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/28.
//

import SwiftUI
import LDKNode

@MainActor
class LightningViewModel: ObservableObject {
    @Published var status: NodeStatus?
    @Published var nodeId: String?
    @Published var balance: BalanceDetails?
    @Published var peers: [PeerDetails]?

    func start() async throws {
        let mnemonic = "science fatigue phone inner pipe solve acquire nothing birth slow armor flip debate gorilla select settle talk badge uphold firm video vibrant banner casual" // = generateEntropyMnemonic()
        let passphrase: String? = nil
        
        try LightningService.shared.setup(mnemonic: mnemonic, passphrase: passphrase)
        try LightningService.shared.start()
        await sync()
    }
    
    func sync() async {
        do {
            try LightningService.shared.sync()
            status = LightningService.shared.status
            nodeId = LightningService.shared.nodeId
            balance = LightningService.shared.balances
            peers = LightningService.shared.peers
            
            //TODO sync everything else for the UI
        } catch {
            print("Error: \(error)")
        }
    }
}
