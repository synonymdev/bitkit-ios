//
//  ContentView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject var wallet = WalletViewModel.shared

    var body: some View {
        VStack {
            if wallet.walletExists == nil {
                ProgressView()
            } else if wallet.walletExists == true {
                HomeView()
            } else {
                WelcomeView()
            }
        }
        .onChange(of: wallet.walletExists) { _ in
            Logger.info("Wallet exists state changed: \(wallet.walletExists?.description ?? "nil")")
            if wallet.walletExists == true {
                StartupHandler.startAllServices()
            }
        }
        .onAppear {
            wallet.setWalletExistsState()
        }
        .handleLightningStateOnScenePhaseChange() // Will stop and start LN node as needed
    }
}

#Preview {
    ContentView()
}
