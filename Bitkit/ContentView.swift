//
//  ContentView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject var lnViewModel = LightningViewModel()
    
    var body: some View {
        VStack {
            Text("LDK-Node running: \(lnViewModel.status?.isRunning == true ? "✅" : "❌")")
        }
        .padding()
        .onAppear {
            Task {
                do {
                    try await lnViewModel.start()
                } catch {
                    print("Error: \(error)")
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
