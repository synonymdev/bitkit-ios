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
    
    func start() async throws {
        try LightningService.shared.setup()
        try LightningService.shared.start()
        await sync()
    }
    
    func sync() async {
        do {
            try LightningService.shared.sync()
            status = LightningService.shared.status
            
            //TODO sync everything else for the UI
        } catch {
            print("Error: \(error)")
        }
    }
}
