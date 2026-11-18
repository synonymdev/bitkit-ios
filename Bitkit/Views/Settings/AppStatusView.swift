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

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    internetStatusRow
                    bitcoinNodeStatusRow
                    nodeStatusRow
                    channelsStatusRow
                    sparkStatusRow
                    backupStatusRow
                }
            }
            .refreshable {
                await refreshAppStatus()
            }

            BodyMText(t("settings__status__app_version", variables: ["version": appVersion]), textColor: .white64)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
                .accessibilityIdentifier("AppVersion")
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
        let description = t("settings__status__electrum__\(status.rawValue)")

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
        let description = t("settings__status__lightning_node__\(status.rawValue)")

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
        let status = AppStatusHelper.channelsStatus(from: wallet, network: network)
        let isViaSpark = AppStatusHelper.isLightningViaSpark(from: wallet, network: network)
        let description = t("settings__status__lightning_connection__\(isViaSpark ? "spark" : status.rawValue)")

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

    /// The app's version and build, as "3.2.0 (182)".
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }

    /// Spark's connection, or a running force transfer to savings, which taps through to its progress.
    @ViewBuilder
    private var sparkStatusRow: some View {
        let exit = SparkExitManager.shared
        if let step = AppStatusHelper.exitStep(record: exit.record, fundingState: exit.fundingState) {
            StatusRow(
                imageName: "warning",
                title: t("settings__status__spark__title"),
                description: t(step == .funding ? "settings__status__exit__funding" : "settings__status__spark__exit"),
                status: .pending,
                onTap: {
                    navigation.navigate(.sparkExitProgress)
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Status-spark_exit")
        } else if let status = AppStatusHelper.sparkStatus(network: network) {
            StatusRow(
                imageName: "asterisk",
                title: t("settings__status__spark__title"),
                description: t("settings__status__spark__\(status.rawValue)"),
                status: status,
                // Spark's detail shows a zero balance until Spark has read its state.
                onTap: status == .ready ? { navigation.navigate(.sparkConnectionDetail) } : nil
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Status-spark")
        }
    }

    private var backupStatusRow: some View {
        let description: String
        let status: HealthStatus

        if let timestamp = backupTimestamp {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            // The frame's "Jan 2, 2023 at 11:45 PM" in US English: each locale's own order, words and hour cycle (j).
            formatter.setLocalizedDateFormatFromTemplate("MMMdyyyyjjmm")
            description = formatter.string(from: date)
            status = .ready
        } else {
            description = t("settings__status__backup__error")
            status = .error
        }

        return StatusRow(
            imageName: "cloud-check",
            title: t("settings__status__backup__title"),
            description: description,
            status: status,
            onTap: {
                navigation.navigate(.dataBackups)
            }
        )
        .accessibilityIdentifier("Status-backup")
    }
}
