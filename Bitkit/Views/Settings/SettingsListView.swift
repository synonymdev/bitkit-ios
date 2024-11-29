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
            Section {
                NavigationLink(destination: GeneralSettingsView()) {
                    Label {
                        Text("General")
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }

                NavigationLink(destination: LightningSettingsView()) {
                    Label {
                        Text("Lightning")
                    } icon: {
                        Image(systemName: "bolt.fill")
                    }
                }

                NavigationLink(destination: LogView()) {
                    Label {
                        Text("Logs")
                    } icon: {
                        Image(systemName: "doc.text.fill")
                    }
                }
            }

            Section {
                Button {
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
                } label: {
                    Label {
                        Text("Wipe Wallet")
                    } icon: {
                        Image(systemName: "trash.fill")
                    }
                    .foregroundColor(.red)
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Only available in regtest mode")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            app.showTabBar = false
        }
    }
}

#Preview {
    SettingsListView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
}
