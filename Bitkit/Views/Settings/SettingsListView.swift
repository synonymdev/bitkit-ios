//
//  SettingsListView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct SettingsListView: View {
    @ObservedObject var wallet = WalletViewModel.shared

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
                        return
                    }
                    do {
                        // Delete storage (for current wallet only)
                        try await wallet.wipeOnchainWallet()
                        try await wallet.wipeLightningWallet()
                        // Delete entire keychain
                        try Keychain.wipeEntireKeychain()
                        wallet.setWalletExistsState()
                    } catch {
                        Logger.error(error, context: "Nuke")
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsListView()
}
