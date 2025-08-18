import BitkitCore
import LDKNode
import SwiftUI

struct LightningConnectionsView: View {
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var showClosedConnections = false
    @State private var isRefreshing = false

    var body: some View {
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
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()

                // Pending Connections section
                if !pendingChannels.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            CaptionMText(t("lightning__conn_pending"))
                                .padding(.top, 32)
                                .padding(.bottom, 16)
                            Spacer()
                        }

                        ForEach(Array(pendingChannels.enumerated()), id: \.element.channelId) { index, channel in
                            NavigationLink(
                                destination: LightningConnectionDetailView(
                                    channel: channel,
                                    linkedOrder: findLinkedOrder(for: channel),
                                    title: "\(t("lightning__connection")) \(index + 1)"
                                )
                            ) {
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
                                        status: .pending
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

                // Open Connections section
                if !openChannels.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            CaptionMText(t("lightning__conn_open"))
                                .padding(.top, 16)
                                .padding(.bottom, 16)
                            Spacer()
                        }

                        ForEach(Array(openChannels.enumerated()), id: \.element.channelId) { index, channel in
                            NavigationLink(
                                destination: LightningConnectionDetailView(
                                    channel: channel,
                                    linkedOrder: findLinkedOrder(for: channel),
                                    title: "\(t("lightning__connection")) \(index + 1)"
                                )
                            ) {
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
                if showClosedConnections && !closedConnections.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            CaptionMText(t("lightning__conn_closed"))
                                .padding(.top, 16)
                                .padding(.bottom, 16)
                            Spacer()
                        }

                        ForEach(Array(closedConnections.enumerated()), id: \.element.id) { index, order in
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
                                    capacity: order.lspBalanceSat + order.clientBalanceSat,
                                    localBalance: order.clientBalanceSat,
                                    remoteBalance: order.lspBalanceSat,
                                    status: .closed
                                )
                                .padding(.bottom, 16)

                                Divider()
                            }
                            .opacity(0.64)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Handle tap for order details
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }

                if !closedConnections.isEmpty {
                    // Show Closed & Failed button
                    CustomButton(
                        title: showClosedConnections
                            ? t("lightning__conn_closed_hide")
                            : t("lightning__conn_closed_show"),
                        variant: .tertiary,
                    ) {
                        showClosedConnections.toggle()
                    }
                    .padding(.top, 16)
                }

                Spacer()
                    .frame(height: 32)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.black)
        .navigationTitle(t("lightning__connections"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshData()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(value: Route.fundingOptions) {
                    Image(systemName: "plus")
                        .foregroundColor(.white)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                CustomButton(
                    title: t("lightning__conn_button_export_logs"),
                    variant: .secondary,
                    shouldExpand: true
                ) {
                    // Handle export logs
                }

                CustomButton(
                    title: t("lightning__conn_button_add"),
                    variant: .primary,
                    shouldExpand: true,
                ) {
                    navigation.navigate(.fundingOptions)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Computed Properties

    private var spendingBalance: UInt64 {
        guard let balanceDetails = wallet.balanceDetails else { return 0 }
        return balanceDetails.totalLightningBalanceSats
    }

    private var receivingCapacity: UInt64 {
        wallet.incomingLightningCapacitySats ?? 0
    }

    private var pendingChannels: [ChannelDetails] {
        guard let channels = wallet.channels else { return [] }
        return channels.filter { !$0.isChannelReady }
    }

    private var openChannels: [ChannelDetails] {
        guard let channels = wallet.channels else { return [] }
        return channels.filter(\.isChannelReady)
    }

    private var closedConnections: [IBtOrder] {
        guard let orders = blocktank.orders else { return [] }
        return orders.filter { $0.state == .closed }
    }

    // MARK: - Helper Methods

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
        }

        isRefreshing = false
    }

    private func findLinkedOrder(for channel: ChannelDetails) -> IBtOrder? {
        guard let orders = blocktank.orders else { return nil }

        // Try to match by short channel ID first (most reliable)
        if let shortChannelId = channel.shortChannelId {
            let shortChannelIdString = String(shortChannelId)
            for order in orders {
                if let orderChannel = order.channel,
                   let orderShortChannelId = orderChannel.shortChannelId,
                   orderShortChannelId == shortChannelIdString
                {
                    return order
                }
            }
        }

        // Try to match by funding transaction if available
        if let fundingTxo = channel.fundingTxo {
            for order in orders {
                if let orderChannel = order.channel,
                   orderChannel.fundingTx.id == fundingTxo.txid
                {
                    return order
                }
            }
        }

        // Try to match by counterparty node ID (less reliable, could match multiple)
        let counterpartyNodeIdString = channel.counterpartyNodeId.description
        for order in orders {
            if let orderChannel = order.channel,
               orderChannel.clientNodePubkey == counterpartyNodeIdString || orderChannel.lspNodePubkey == counterpartyNodeIdString
            {
                return order
            }
        }

        return nil
    }

    private func formatNumber(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
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
