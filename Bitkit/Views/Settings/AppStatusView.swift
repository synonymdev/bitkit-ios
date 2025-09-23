import SwiftUI

struct AppStatusView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var wallet: WalletViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__status__title"))
                .padding(.bottom, 16)

            VStack(spacing: 16) {
                internetStatusRow
                nodeStatusRow
                channelsStatusRow
            }

            Spacer()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onAppear {
            wallet.syncState()
        }
    }

    // MARK: - Status Rows

    private var internetStatusRow: some View {
        let status = AppStatusHelper.internetStatus(network: network)
        let description = status == .ready ? t("settings__status__internet__ready") : t("settings__status__internet__error")

        return StatusRow(
            imageName: "status-internet",
            title: t("settings__status__internet__title"),
            description: description,
            status: status,
            onTap: {
                if let settingsUrl = URL(string: "App-Prefs:Settings") {
                    UIApplication.shared.open(settingsUrl)
                }
            }
        )
    }

    private var nodeStatusRow: some View {
        let status = AppStatusHelper.nodeStatus(from: wallet, network: network)
        let description: String = t("settings__status__lightning_node__\(status.rawValue)")

        return StatusRow(
            imageName: "status-node",
            title: t("settings__status__lightning_node__title"),
            description: description,
            status: status,
            onTap: {
                navigation.navigate(.node)
            }
        )
    }

    private var channelsStatusRow: some View {
        let status = AppStatusHelper.channelsStatus(from: wallet)
        let description: String = t("settings__status__lightning_connection__\(status.rawValue)")

        return StatusRow(
            imageName: "status-lightning",
            title: t("settings__status__lightning_connection__title"),
            description: description,
            status: status,
            onTap: {
                navigation.navigate(.connections)
            }
        )
    }
}
