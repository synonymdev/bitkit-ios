//
//  SettingsListView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct SettingsListView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        List {
            NavigationLink(destination: LightningSettingsView()) {
                Text("Lightning")
            }

            NavigationLink(destination: LogView()) {
                Text("Logs")
            }

            Button("Wipe Wallet") {
                Task {
                    guard Env.network == .regtest else {
                        Logger.error("Can only nuke on regtest")
                        app.toast(type: .error, title: "Error", description: "Can only nuke on regtest")
                        return
                    }
                    do {
                        // Delete storage (for current wallet only)
                        try await wallet.wipeLightningWallet()
                        // Delete entire keychain
                        try Keychain.wipeEntireKeychain()
                        try wallet.setWalletExistsState()
                    } catch {
                        app.toast(error)
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsListView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
}
