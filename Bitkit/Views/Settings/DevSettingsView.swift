import SwiftUI
import UIKit

struct DevSettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var session: SessionManager
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if Env.network == .regtest {
                    NavigationLink(value: Route.blocktankRegtest) {
                        SettingsListLabel(title: "Blocktank Regtest")
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

                NavigationLink(value: Route.logs) {
                    SettingsListLabel(title: "Show Logs")
                }

                Button {
                    Task {
                        guard let zipURL = LogService.shared.zipLogs() else {
                            app.toast(type: .error, title: "Error", description: "Failed to create log zip file")
                            return
                        }

                        // Present share sheet
                        await MainActor.run {
                            let activityViewController = UIActivityViewController(
                                activityItems: [zipURL],
                                applicationActivities: nil
                            )

                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let window = windowScene.windows.first
                            {
                                window.rootViewController?.present(activityViewController, animated: true)
                            }
                        }
                    }
                } label: {
                    SettingsListLabel(title: "Export Logs", rightIcon: nil)
                }

                Button {
                    Task {
                        do {
                            try await AppReset.wipe(
                                app: app,
                                wallet: wallet,
                                session: session
                            )
                        } catch {
                            app.toast(error)
                        }
                    }
                } label: {
                    SettingsListLabel(title: "Wipe Wallet", rightIcon: nil)
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle(localizedString("settings__dev_title"))
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
