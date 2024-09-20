//
//  ContentView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject var wallet = WalletViewModel.shared

    @StateObject private var toast = ToastViewModel()

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
        .environment(\.toast, toast)
        .toast(viewModel: toast)
        .onChange(of: wallet.walletExists) { _ in
            Logger.info("Wallet exists state changed: \(wallet.walletExists?.description ?? "nil")")
            if wallet.walletExists == true {
                StartupHandler.startAllServices()
            }
        }
        .task {
            do {
                try wallet.setWalletExistsState()
            } catch {
                toast.show(error)
            }
        }
        .handleLightningStateOnScenePhaseChange() // Will stop and start LN node as needed
    }
}

#Preview {
    ContentView()
}
