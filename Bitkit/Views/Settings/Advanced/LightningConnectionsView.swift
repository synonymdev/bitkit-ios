import BitkitCore
import LDKNode
import SwiftUI

struct LightningConnectionsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var showClosedConnections = false
    @State private var isRefreshing = false

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
                                    NavigationLink(destination: LightningConnectionDetailView(
                                        channel: channel,
                                        linkedOrder: findLinkedOrder(for: channel),
                                        title: "\(t("lightning__connection")) \(index + 1)"
                                    )) {
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
                        if showClosedConnections && !closedConnections.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                CaptionMText(t("lightning__conn_closed"))
                                    .padding(.top, 16)

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
    }

    // MARK: - Computed Properties

    private var spendingBalance: UInt64 {
        guard let balanceDetails = wallet.balanceDetails else { return 0 }
        return balanceDetails.totalLightningBalanceSats
    }

    private var receivingCapacity: UInt64 {
        wallet.totalInboundLightningSats ?? 0
    }

    private var pendingChannels: [ChannelDetails] {
        guard let channels = wallet.channels else { return [] }
        return channels.filter { !$0.isChannelReady }
    }

    private var pendingOrders: [IBtOrder] {
        guard let orders = blocktank.orders else { return [] }
        return orders.filter { order in
            // Include orders that are created or paid but not yet opened
            order.state2 == .created || order.state2 == .paid
        }
    }

    private var pendingConnections: [ChannelDetails] {
        var connections: [ChannelDetails] = []

        // Add actual pending channels
        connections.append(contentsOf: pendingChannels)

        // Create fake channels from pending orders
        for order in pendingOrders {
            let fakeChannel = createFakeChannel(from: order)
            connections.append(fakeChannel)
        }

        return connections
    }

    /// Creates a fake channel from a Blocktank order for UI display purposes
    private func createFakeChannel(from order: IBtOrder) -> ChannelDetails {
        return ChannelDetails(
            channelId: order.id,
            counterpartyNodeId: order.lspNode?.pubkey ?? "",
            fundingTxo: OutPoint(txid: Txid(order.channel?.fundingTx.id ?? ""), vout: UInt32(order.channel?.fundingTx.vout ?? 0)),
            shortChannelId: order.channel?.shortChannelId.flatMap(UInt64.init),
            outboundScidAlias: nil,
            inboundScidAlias: nil,
            channelValueSats: order.lspBalanceSat + order.clientBalanceSat,
            unspendablePunishmentReserve: 1000,
            userChannelId: order.id,
            feerateSatPer1000Weight: 2500,
            outboundCapacityMsat: order.clientBalanceSat * 1000,
            inboundCapacityMsat: order.lspBalanceSat * 1000,
            confirmationsRequired: nil,
            confirmations: 0,
            isOutbound: false,
            isChannelReady: false,
            isUsable: false,
            isAnnounced: false,
            cltvExpiryDelta: 144,
            counterpartyUnspendablePunishmentReserve: 1000,
            counterpartyOutboundHtlcMinimumMsat: 1000,
            counterpartyOutboundHtlcMaximumMsat: 99_000_000,
            counterpartyForwardingInfoFeeBaseMsat: 1000,
            counterpartyForwardingInfoFeeProportionalMillionths: 100,
            counterpartyForwardingInfoCltvExpiryDelta: 144,
            nextOutboundHtlcLimitMsat: order.clientBalanceSat * 1000,
            nextOutboundHtlcMinimumMsat: 1000,
            forceCloseSpendDelay: nil,
            inboundHtlcMinimumMsat: 1000,
            inboundHtlcMaximumMsat: order.lspBalanceSat * 1000,
            config: .init(
                forwardingFeeProportionalMillionths: 0,
                forwardingFeeBaseMsat: 0,
                cltvExpiryDelta: 0,
                maxDustHtlcExposure: .feeRateMultiplier(multiplier: 0),
                forceCloseAvoidanceMaxFeeSatoshis: 0,
                acceptUnderpayingHtlcs: true
            )
        )
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

        // For fake channels created from orders, match by userChannelId (which we set to order.id)
        for order in orders {
            if order.id == channel.userChannelId {
                return order
            }
        }

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
