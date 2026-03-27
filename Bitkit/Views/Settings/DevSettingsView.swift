import SwiftUI
import UIKit

struct DevSettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var notificationManager: PushNotificationManager
    @EnvironmentObject var session: SessionManager
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__dev_title"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if Env.network == .regtest {
                        NavigationLink(value: Route.blocktankRegtest) {
                            SettingsRow(title: "Blocktank Regtest")
                        }
                    }

                    if Env.network == .regtest {
                        SettingsRow(
                            title: "Override Fees",
                            rightIcon: nil,
                            toggle: $feeEstimatesManager.devOverrideFeeEstimates
                        )
                    }

                    NavigationLink(value: Route.ldkDebug) {
                        SettingsRow(title: "LDK")
                    }

                    NavigationLink(value: Route.vssDebug) {
                        SettingsRow(title: "VSS")
                    }

                    NavigationLink(value: Route.probingTool) {
                        SettingsRow(title: "Probing Tool")
                    }

                    NavigationLink(value: Route.orders) {
                        SettingsRow(title: "Orders")
                    }

                    Button {
                        Task {
                            do {
                                try await CoreService.shared.activity.generateRandomTestData()
                                await activity.syncState()
                                app.toast(type: .success, title: "Success", description: "Generated test activities")
                            } catch {
                                app.toast(type: .error, title: "Error", description: "Failed to generate activities: \(error.localizedDescription)")
                            }
                        }
                    } label: {
                        SettingsRow(title: "Generate Test Activities", rightIcon: nil)
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
                        SettingsRow(title: "Reset All Activities", rightIcon: nil)
                    }

                    NavigationLink(value: Route.logs) {
                        SettingsRow(title: "Show Logs")
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
                        SettingsRow(title: "Export Logs", rightIcon: nil)
                    }

                    Button {
                        Task {
                            do {
                                try await notificationManager.sendTestNotification()
                            } catch {
                                Logger.error(error, context: "failed to test push notification")
                                app.toast(
                                    type: .error,
                                    title: "Error",
                                    description: "Failed to send test notification: \(error)"
                                )
                            }
                        }
                    } label: {
                        SettingsRow(title: "Test Push Notification", rightIcon: nil)
                    }

                    Button {
                        fatalError("Simulate Crash")
                    } label: {
                        SettingsRow(title: "Simulate Crash", rightIcon: nil)
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
                        SettingsRow(title: "Wipe Wallet", rightIcon: nil)
                    }
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
    }
}

#Preview {
    DevSettingsView()
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
        .environmentObject(FeeEstimatesManager())
        .environmentObject(NavigationViewModel())
        .environmentObject(WalletViewModel())
        .environmentObject(WidgetsViewModel())
        .preferredColorScheme(.dark)
}
