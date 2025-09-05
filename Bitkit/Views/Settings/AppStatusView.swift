import SwiftUI

struct AppStatusView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__status__title"))

            List {
                internetStatusView
                NavigationLink(value: Route.node) {
                    lightningNodeStatusView
                }
                lightningConnectionStatusView // TODO: navigate to channel list view
            }
            .scrollContentBackground(.hidden)
            .listStyle(PlainListStyle())
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onAppear {
            wallet.syncState()
        }
    }

    private var internetStatusView: some View {
        let isConnected = app.networkStatus == .wifi || app.networkStatus == .cellular
        let iconBackgroundColor: Color = isConnected ? .green16 : .red16
        let iconColor: Color = isConnected ? .greenAccent : .redAccent
        let status =
            isConnected
                ? t("settings__status__internet__ready", comment: "Connected")
                : t("settings__status__internet__error", comment: "Disconnected")
        let statusColor: Color = isConnected ? .greenAccent : .redAccent

        return StatusItemView(
            imageName: "status-internet",
            iconBackgroundColor: iconBackgroundColor,
            iconColor: iconColor,
            title: t("settings__status__internet__title"),
            status: status,
            statusColor: statusColor
        )
    }

    private var lightningNodeStatusView: some View {
        return StatusItemView(
            imageName: "status-node",
            iconBackgroundColor: .green16,
            iconColor: wallet.nodeLifecycleState.statusColor,
            title: t("settings__status__lightning_node__title"),
            status: wallet.nodeLifecycleState.displayState,
            statusColor: wallet.nodeLifecycleState.statusColor
        )
    }

    private var lightningConnectionStatusView: some View {
        let hasChannels = (wallet.channelCount > 0)
        let hasUsableChannels = wallet.channels?.contains(where: \.isUsable) ?? false
        let hasReadyChannels = wallet.channels?.contains(where: \.isChannelReady) ?? false

        let connectionColor: Color = {
            if !hasChannels {
                return .redAccent
            } else if hasUsableChannels {
                return .greenAccent
            } else {
                return .yellowAccent
            }
        }()

        let iconBackgroundColor: Color = {
            if !hasChannels {
                return .red16
            } else if hasUsableChannels {
                return .green16
            } else {
                return .yellow16
            }
        }()

        let connectionStatus: String = {
            if !hasChannels {
                return t("settings__status__lightning_connection__error")
            } else if hasUsableChannels && hasReadyChannels {
                return t("settings__status__lightning_connection__ready")
            } else if !hasUsableChannels && hasReadyChannels {
                return t("settings__status__lightning_connection__pending")
            } else {
                return t("settings__status__lightning_connection__ready")
            }
        }()

        return StatusItemView(
            imageName: "status-lightning",
            iconBackgroundColor: iconBackgroundColor,
            iconColor: connectionColor,
            title: t("settings__status__lightning_connection__title"),
            status: connectionStatus,
            statusColor: connectionColor,
        )
    }
}

private struct StatusItemView: View {
    let imageName: String
    let iconBackgroundColor: Color
    let iconColor: Color
    let title: String
    let status: String
    let statusColor: Color

    var body: some View {
        HStack(spacing: 16) {
            CircularIcon(
                icon: imageName,
                iconColor: iconColor,
                backgroundColor: iconBackgroundColor,
                size: 40
            )

            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(title)
                CaptionBText(status)
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .listRowBackground(Color.black)
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color.white.opacity(0.1))
    }
}

#Preview {
    NavigationStack {
        AppStatusView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
    }
}
