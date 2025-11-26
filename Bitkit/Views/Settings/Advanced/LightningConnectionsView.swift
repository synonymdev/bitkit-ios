import BitkitCore
import LDKNode
import SwiftUI

struct LightningConnectionsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var channelDetails: ChannelDetailsViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var showClosedConnections = false
    @State private var isRefreshing = false
    @State private var closedChannels: [ClosedChannelDetails] = []
    @State private var pendingConnections: [ChannelDetails] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: t("lightning__connections"),
                action: AnyView(
                    NavigationLink(value: Route.fundingOptions) {
                        Image("plus")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.textPrimary)
                    }
                    .accessibilityIdentifier("NavigationAction")
                )
            )
            .padding(.bottom, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header section with spending balance and receiving capacity
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                CaptionMText(t("lightning__spending_label"))
                                HStack(spacing: 4) {
                                    Image("arrow-up")
                                        .resizable()
                                        .frame(width: 22, height: 22)
                                        .foregroundColor(.purpleAccent)
                                    TitleText(formatNumber(spendingBalance), textColor: .purpleAccent)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: 4) {
                                CaptionMText(t("lightning__receiving_label"))
                                HStack(spacing: 4) {
                                    Image("arrow-down")
                                        .resizable()
                                        .frame(width: 22, height: 22)
                                        .foregroundColor(.white)
                                    TitleText(formatNumber(receivingCapacity), textColor: .white)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.bottom, 16)

                        Divider()

                        // Pending Connections section
                        if !pendingConnections.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                CaptionMText(t("lightning__conn_pending"))
                                    .padding(.top, 16)

                                ForEach(Array(pendingConnections.enumerated()), id: \.element.channelId) { index, channel in
                                    Button {
                                        navigation.navigate(.connectionDetail(channelId: channel.channelIdString))
                                    } label: {
                                        VStack(spacing: 0) {
                                            HStack {
                                                SubtitleText("\(t("lightning__connection")) \(index + 1)")
                                                Spacer()
                                                Image("chevron")
                                                    .resizable()
                                                    .foregroundColor(.textSecondary)
                                                    .frame(width: 24, height: 24)
                                            }
                                            .padding(.bottom, 6)

                                            LightningChannel(
                                                capacity: channel.channelValueSats,
                                                localBalance: channel.outboundCapacityMsat / 1000,
                                                remoteBalance: channel.inboundCapacityMsat / 1000,
                                                status: .pending
                                            )
                                            .padding(.bottom, 16)

                                            Divider()
                                        }
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.bottom, 16)
                        }

                        // Open Connections section
                        if !openChannels.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                CaptionMText(t("lightning__conn_open"))
                                    .padding(.top, 16)

                                ForEach(Array(openChannels.enumerated()), id: \.element.channelId) { index, channel in
                                    Button {
                                        navigation.navigate(.connectionDetail(channelId: channel.channelIdString))
                                    } label: {
                                        VStack(spacing: 0) {
                                            HStack {
                                                SubtitleText("\(t("lightning__connection")) \(index + 1)")
                                                Spacer()
                                                Image("chevron")
                                                    .resizable()
                                                    .foregroundColor(.textSecondary)
                                                    .frame(width: 24, height: 24)
                                            }
                                            .padding(.bottom, 6)

                                            LightningChannel(
                                                capacity: channel.channelValueSats,
                                                localBalance: channel.outboundCapacityMsat / 1000,
                                                remoteBalance: channel.inboundCapacityMsat / 1000,
                                                status: .open
                                            )
                                            .padding(.bottom, 16)

                                            Divider()
                                        }
                                        .opacity((!channel.isChannelReady || !channel.isUsable) ? 0.64 : 1.0)
                                    }
                                }
                            }
                        }

                        // Closed Connections section
                        if showClosedConnections && !closedChannels.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                CaptionMText(t("lightning__conn_closed"))
                                    .padding(.top, 16)

                                ForEach(Array(closedChannels.enumerated()), id: \.element.channelId) { index, channel in
                                    Button {
                                        navigation.navigate(.connectionDetail(channelId: channel.channelIdString))
                                    } label: {
                                        VStack(spacing: 0) {
                                            HStack {
                                                SubtitleText("\(t("lightning__connection")) \(index + 1)")
                                                Spacer()
                                                Image("chevron")
                                                    .resizable()
                                                    .foregroundColor(.textSecondary)
                                                    .frame(width: 24, height: 24)
                                            }
                                            .padding(.bottom, 12)

                                            LightningChannel(
                                                capacity: channel.channelValueSats,
                                                localBalance: channel.outboundCapacityMsat / 1000,
                                                remoteBalance: channel.inboundCapacityMsat / 1000,
                                                status: .closed
                                            )
                                            .padding(.bottom, 16)

                                            Divider()
                                        }
                                        .opacity(0.64)
                                    }
                                }
                            }
                            .padding(.bottom, 16)
                        }

                        if !closedChannels.isEmpty {
                            // Show Closed & Failed button
                            CustomButton(
                                title: showClosedConnections
                                    ? t("lightning__conn_closed_hide")
                                    : t("lightning__conn_closed_show"),
                                variant: .tertiary
                            ) {
                                showClosedConnections.toggle()
                            }
                            .padding(.top, 16)
                        }

                        Spacer()
                        // .frame(height: 32)

                        HStack(spacing: 16) {
                            CustomButton(title: t("lightning__conn_button_export_logs"), variant: .secondary) {
                                onExportLogs()
                            }

                            CustomButton(title: t("lightning__conn_button_add")) {
                                navigation.navigate(.fundingOptions)
                            }
                        }
                    }
                    .frame(minHeight: geometry.size.height)
                    .bottomSafeAreaPadding()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .refreshable {
            await refreshData()
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Computed Properties

    private var spendingBalance: UInt64 {
        guard let balanceDetails = wallet.balanceDetails else { return 0 }
        return balanceDetails.totalLightningBalanceSats
    }

    private var receivingCapacity: UInt64 {
        wallet.totalInboundLightningSats ?? 0
    }

    private var openChannels: [ChannelDetails] {
        guard let channels = wallet.channels else { return [] }
        return channels.filter(\.isChannelReady)
    }

    // MARK: - Helper Methods

    private func loadData() async {
        await withTaskGroup(of: Void.self) { group in
            // Load pending connections
            group.addTask {
                let connections = await channelDetails.pendingConnections(wallet: wallet)
                await MainActor.run {
                    pendingConnections = connections
                }
            }

            // Load closed channels
            group.addTask {
                do {
                    let channels = try await CoreService.shared.activity.closedChannels()
                    await MainActor.run {
                        closedChannels = channels
                    }
                } catch {
                    Logger.error("Failed to load closed channels: \(error)")
                }
            }
        }
    }

    private func refreshData() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        await withTaskGroup(of: Void.self) { group in
            // Refresh Blocktank orders
            group.addTask {
                do {
                    try await blocktank.refreshOrders()
                } catch {
                    Logger.error("Failed to refresh Blocktank orders: \(error)")
                }
            }

            // Sync wallet channels
            group.addTask {
                do {
                    try await wallet.sync()
                } catch {
                    Logger.error("Failed to sync wallet: \(error)")
                }
            }

            // Load closed channels from bitkit-core
            group.addTask {
                do {
                    let channels = try await CoreService.shared.activity.closedChannels()
                    await MainActor.run {
                        closedChannels = channels
                    }
                } catch {
                    Logger.error("Failed to load closed channels: \(error)")
                }
            }
        }

        // Reload after refresh
        await loadData()

        isRefreshing = false
    }

    private func formatNumber(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    private func onExportLogs() {
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
    }
}

#Preview {
    NavigationStack {
        LightningConnectionsView()
            .environmentObject(WalletViewModel())
            .environmentObject(BlocktankViewModel())
    }
    .preferredColorScheme(.dark)
}
