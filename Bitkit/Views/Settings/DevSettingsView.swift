import SwiftUI

struct DevSettingsView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    var body: some View {
        List {
            Section {
                if Env.network == .regtest {
                    NavigationLink(destination: BlocktankRegtestView()) {
                        Label {
                            Text("Blocktank Regtest")
                        } icon: {
                            Image(systemName: "hammer.fill")
                        }
                    }
                }

                Button {
                    Task {
                        do {
                            try await CoreService.shared.activity.removeAll()
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
                    .foregroundColor(.redAccent)
                }

                Button {
                    Task {
                        do {
                            try await CoreService.shared.activity.generateRandomTestData(count: 100)
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
                            // TODO: reset all of app state
                            navigation.reset()
                            app.hasSeenTransferToSavingsIntro = false
                            app.hasSeenTransferToSpendingIntro = false
                            app.hasSeenWidgetsIntro = false
                            widgets.clearWidgets()

                            if wallet.nodeLifecycleState == .running || wallet.nodeLifecycleState == .starting
                                || wallet.nodeLifecycleState == .stopping
                            {
                                try await wallet.wipeLightningWallet()
                            }
                            try await CoreService.shared.activity.removeAll()
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
                    .foregroundColor(.redAccent)
                }
            } header: {
                Text("Development Tools")
            }
        }
        .navigationTitle("Dev Settings")
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview {
    DevSettingsView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
        .environmentObject(NavigationViewModel())
        .environmentObject(WidgetsViewModel())
        .preferredColorScheme(.dark)
}
