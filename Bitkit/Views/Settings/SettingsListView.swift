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
    @EnvironmentObject var activity: ActivityListViewModel

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

                NavigationLink(destination: BackupSettingsView()) {
                    Label {
                        Text("Back Up Or Restore")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
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
                if Env.network == .regtest {
                    NavigationLink(destination: BlocktankRegtestView()) {
                        Label {
                            Text("Blocktank Regtest")
                        } icon: {
                            Image(systemName: "hammer.fill")
                        }
                    }

                    Button {
                        Task {
                            do {
                                try await ActivityListService.shared.removeAll()
                                await activity.syncState()
                                app.toast(type: .success, title: "Success", description: "All activities removed")
                            } catch {
                                app.toast(type: .error, title: "Error", description: "Failed to remove activities: \(error.localizedDescription)")
                            }
                        }
                    } label: {
                        Label {
                            Text("Reset All Activities")
                        } icon: {
                            Image(systemName: "clock.badge.xmark")
                        }
                        .foregroundColor(.red)
                    }
                    
                    Button {
                        Task {
                            do {
                                try await ActivityListService.shared.generateRandomTestData()
                                await activity.syncState()
                                app.toast(type: .success, title: "Success", description: "Generated 100 random activities")
                            } catch {
                                app.toast(type: .error, title: "Error", description: "Failed to generate activities: \(error.localizedDescription)")
                            }
                        }
                    } label: {
                        Label {
                            Text("Generate Test Activities")
                        } icon: {
                            Image(systemName: "ladybug.fill")
                        }
                        .foregroundColor(.orange)
                    }

                    Button {
                        Task {
                            guard Env.network == .regtest else {
                                Logger.error("Can only nuke on regtest")
                                app.toast(type: .error, title: "Error", description: "Can only nuke on regtest")
                                return
                            }
                            do {
                                if wallet.nodeLifecycleState == .running || wallet.nodeLifecycleState == .starting || wallet.nodeLifecycleState == .stopping {
                                    try await wallet.wipeLightningWallet()
                                }
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
                }
            } header: {
                Text("Regtest only")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            app.showTabBar = false
        }
    }
}

#Preview {
    SettingsListView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
}
