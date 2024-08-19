//
//  ContentView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject var viewModel = ViewModel.shared
    
    var body: some View {
        VStack {
            if viewModel.walletExists == nil {
                ProgressView()
            } else if viewModel.walletExists == true {
                HomeView()
            } else {
                WelcomeView()
            }
        }
        .onChange(of: viewModel.walletExists) { _ in
            Logger.info("Wallet exists state changed: \(viewModel.walletExists?.description ?? "nil")")
            if viewModel.walletExists == true {
                StartupHandler.startAllServices()
            }
        }
        .onAppear {
            viewModel.setWalletExistsState()
        }
        .handleLightningStateOnScenePhaseChange() //Will stop and start LN node as needed
    }
}

#Preview {
    ContentView()
}
