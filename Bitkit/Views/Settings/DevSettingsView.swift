import SwiftUI

struct DevSettingsView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    var body: some View {
        ScrollView {
            if Env.network == .regtest {
                NavigationLink(destination: BlocktankRegtestView()) {
                    SettingsListLabel(
                        title: "Blocktank Regtest"
                    )
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
                SettingsListLabel(
                    title: "Reset All Activities",
                    rightIcon: nil
                )
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
                SettingsListLabel(
                    title: "Generate Test Activities",
                    rightIcon: nil
                )
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
                SettingsListLabel(
                    title: "Wipe Wallet",
                    rightIcon: nil
                )
            }
        }
        .navigationTitle("Dev Settings")
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
