import BitkitCore
import LDKNode
import SwiftUI

struct LightningConnectionDetailView: View {
    let channel: ChannelDetails
    let linkedOrder: IBtOrder?
    let title: String

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: title)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Channel Visualization
                    VStack(spacing: 16) {
                        LightningChannel(
                            capacity: channel.channelValueSats,
                            localBalance: channel.outboundCapacityMsat / 1000,
                            remoteBalance: channel.inboundCapacityMsat / 1000,
                            status: channelStatus,
                            showLabels: true
                        )
                    }

                    // STATUS Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            CaptionText(t("lightning__status").uppercased(), textColor: .textSecondary)
                            Spacer()
                        }

                        VStack(spacing: 0) {
                            HStack {
                                Image(statusIcon)
                                    .foregroundColor(statusColor)
                                    .font(.caption)
                                    .frame(width: 32, height: 32)
                                    .background(statusColor.opacity(0.16))
                                    .cornerRadius(200)

                                BodyMText(statusText, textColor: statusColor)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }

                    // ORDER DETAILS Section
                    if let order = linkedOrder {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                CaptionText(t("lightning__order_details").uppercased(), textColor: .textSecondary)
                                Spacer()
                            }

                            VStack(spacing: 0) {
                                DetailRow(label: t("lightning__order"), value: order.id, isFirst: true)

                                if let formattedDate = formatDate(order.createdAt) {
                                    Divider().padding(.horizontal, 16)
                                    DetailRow(label: t("lightning__opened_on"), value: formattedDate)
                                }

                                Divider().padding(.horizontal, 16)
                                DetailRow(
                                    label: t("lightning__transaction"),
                                    value: truncateString(order.payment.onchain.address, length: 16)
                                )
                                Divider().padding(.horizontal, 16)
                                DetailRow(
                                    label: t("lightning__order_fee"), value: "₿ \(formatNumber(order.feeSat))", isLast: true
                                )
                            }
                        }
                    }

                    // BALANCE Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            CaptionText(t("lightning__balance").uppercased(), textColor: .textSecondary)
                            Spacer()
                        }

                        VStack(spacing: 0) {
                            DetailRow(
                                label: t("lightning__receiving_label"),
                                value: "₿ \(formatNumber(channel.inboundCapacityMsat / 1000))", isFirst: true
                            )
                            Divider().padding(.horizontal, 16)
                            DetailRow(
                                label: t("lightning__spending_label"),
                                value: "₿ \(formatNumber(channel.outboundCapacityMsat / 1000))"
                            )
                            Divider().padding(.horizontal, 16)
                            DetailRow(
                                label: t("lightning__reserve_balance"),
                                value: "₿ \(formatNumber(channel.unspendablePunishmentReserve ?? 0))"
                            )
                            Divider().padding(.horizontal, 16)
                            DetailRow(
                                label: t("lightning__total_size"), value: "₿ \(formatNumber(channel.channelValueSats))",
                                isLast: true
                            )
                        }
                    }

                    // FEES Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            CaptionText(t("lightning__fees").uppercased(), textColor: .textSecondary)
                            Spacer()
                        }

                        VStack(spacing: 0) {
                            DetailRow(label: t("lightning__base_fee"), value: "₿ 1", isFirst: true)
                            Divider().padding(.horizontal, 16)
                            DetailRow(label: "Receiving base fee", value: "₿ 1", isLast: true) // TODO: Add localization key for receiving base fee
                        }
                    }

                    // OTHER Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            CaptionText(t("lightning__other").uppercased(), textColor: .textSecondary)
                            Spacer()
                        }

                        VStack(spacing: 0) {
                            let hasDate = isValidDate(linkedOrder?.createdAt)

                            if hasDate, let formattedDate = formatDate(linkedOrder?.createdAt ?? "") {
                                DetailRow(
                                    label: t("lightning__opened_on"),
                                    value: formattedDate,
                                    isFirst: true
                                )
                                Divider().padding(.horizontal, 16)
                                DetailRow(
                                    label: t("lightning__channel_node_id"),
                                    value: truncateString(channel.counterpartyNodeId.description, length: 16), isLast: true
                                )
                            } else {
                                DetailRow(
                                    label: t("lightning__channel_node_id"),
                                    value: truncateString(channel.counterpartyNodeId.description, length: 16),
                                    isFirst: true, isLast: true
                                )
                            }
                        }
                    }

                    // Bottom buttons
                    HStack(spacing: 16) {
                        CustomButton(
                            title: t("lightning__support"),
                            variant: .secondary,
                            shouldExpand: true
                        ) {
                            // Handle support action
                        }

                        if channelStatus == .open {
                            CustomButton(
                                title: t("lightning__close_conn"),
                                variant: .primary,
                                shouldExpand: true,
                                destination: CloseConnectionConfirmation(channel: channel)
                            )
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    // MARK: - Computed Properties

    private var channelStatus: ChannelStatus {
        if !channel.isChannelReady {
            return .pending
        }
        return .open
    }

    private var statusIcon: String {
        switch channelStatus {
        case .pending:
            return "hourglass-simple"
        case .open:
            return "status-lightning"
        case .closed:
            return "x-mark"
        }
    }

    private var statusColor: Color {
        switch channelStatus {
        case .pending:
            return .purpleAccent
        case .open:
            return .greenAccent
        case .closed:
            return .redAccent
        }
    }

    private var statusText: String {
        switch channelStatus {
        case .pending:
            return t("lightning__order_state__opening").capitalized
        case .open:
            return t("lightning__order_state__open").capitalized
        case .closed:
            return t("lightning__order_state__closed").capitalized
        }
    }

    // Helper Views
    private func DetailRow(label: String, value: String, isFirst: Bool = false, isLast: Bool = false) -> some View {
        HStack {
            CaptionBText(label, textColor: .textPrimary)
            Spacer()
            CaptionBText(value, textColor: .white)
        }
        .padding(.vertical, 12)
    }

    // Helper Functions
    private func formatNumber(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    private func formatDate(_ dateString: String) -> String? {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"

        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MMM d, yyyy - HH:mm"

        // Try to parse the input date string
        if let date = inputFormatter.date(from: dateString) {
            return outputFormatter.string(from: date)
        }

        // If parsing fails, try ISO 8601 format
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: dateString) {
            return outputFormatter.string(from: date)
        }

        // Return nil if parsing fails
        return nil
    }

    private func isValidDate(_ dateString: String?) -> Bool {
        guard let dateString, !dateString.isEmpty else { return false }
        return formatDate(dateString) != nil
    }

    private func truncateString(_ string: String, length: Int) -> String {
        if string.count <= length {
            return string
        }
        let startIndex = string.startIndex
        let endIndex = string.index(startIndex, offsetBy: length)
        return String(string[startIndex ..< endIndex]) + "..."
    }
}

#Preview {
    NavigationStack {
        LightningConnectionDetailView(
            channel: ChannelDetails.mock(),
            linkedOrder: IBtOrder.mock(),
            title: "Connection 6"
        )
        .environmentObject(WalletViewModel())
        .environmentObject(BlocktankViewModel())
    }
    .preferredColorScheme(.dark)
}
