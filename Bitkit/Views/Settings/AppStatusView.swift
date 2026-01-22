import SwiftUI

struct AppStatusView: View {
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var app: AppViewModel

    @State private var backupTimestamp: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__status__title"))
                .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 16) {
                    internetStatusRow
                    bitcoinNodeStatusRow
                    nodeStatusRow
                    channelsStatusRow
                    backupStatusRow
                }
            }
            .refreshable {
                await refreshAppStatus()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await wallet.syncStateAsync()
            backupTimestamp = await BackupService.shared.getLatestBackupTime()
        }
    }

    private func refreshAppStatus() async {
        await wallet.syncStateAsync()
        backupTimestamp = await BackupService.shared.getLatestBackupTime()

        if wallet.nodeLifecycleState == .running {
            do {
                try await wallet.sync()
            } catch {
                await MainActor.run {
                    app.toast(error)
                }
            }
        }

        if case .errorStarting = wallet.nodeLifecycleState {
            do {
                try await wallet.start()
            } catch {
                await MainActor.run {
                    app.toast(error)
                }
            }
        } else if wallet.nodeLifecycleState == .stopped {
            do {
                try await wallet.start()
            } catch {
                await MainActor.run {
                    app.toast(error)
                }
            }
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
        .accessibilityIdentifier("Status-internet")
    }

    private var bitcoinNodeStatusRow: some View {
        let status = AppStatusHelper.bitcoinNodeStatus(from: wallet, network: network)
        let description: String = t("settings__status__electrum__\(status.rawValue)")

        return StatusRow(
            imageName: "status-bitcoin",
            title: t("settings__status__electrum__title"),
            description: description,
            status: status,
            onTap: {
                navigation.navigate(.electrumSettings)
            }
        )
        .accessibilityIdentifier("Status-electrum")
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
        .accessibilityIdentifier("Status-lightning_node")
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
        .accessibilityIdentifier("Status-lightning_connection")
    }

    private var backupStatusRow: some View {
        let description: String
        let status: HealthStatus

        if let timestamp = backupTimestamp {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.locale = Locale.current
            description = formatter.string(from: date)
            status = .ready
        } else {
            description = t("settings__status__backup__error")
            status = .error
        }

        return StatusRow(
            imageName: "rewind",
            title: t("settings__status__backup__title"),
            description: description,
            status: status,
            onTap: {
                navigation.navigate(.backupSettings)
            }
        )
        .accessibilityIdentifier("Status-backup")
    }
}
