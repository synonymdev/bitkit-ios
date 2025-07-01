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
        ScrollView {
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
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // STATUS Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        CaptionText(NSLocalizedString("lightning__status", comment: "").uppercased(), textColor: .textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)

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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }

                // ORDER DETAILS Section
                if let order = linkedOrder {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            CaptionText(NSLocalizedString("lightning__order_details", comment: "").uppercased(), textColor: .textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        VStack(spacing: 0) {
                            DetailRow(label: NSLocalizedString("lightning__order", comment: ""), value: order.id, isFirst: true)

                            if let formattedDate = formatDate(order.createdAt) {
                                Divider().padding(.horizontal, 16)
                                DetailRow(label: NSLocalizedString("lightning__opened_on", comment: ""), value: formattedDate)
                            }

                            Divider().padding(.horizontal, 16)
                            DetailRow(
                                label: NSLocalizedString("lightning__transaction", comment: ""),
                                value: truncateString(order.payment.onchain.address, length: 16))
                            Divider().padding(.horizontal, 16)
                            DetailRow(
                                label: NSLocalizedString("lightning__order_fee", comment: ""), value: "₿ \(formatNumber(order.feeSat))", isLast: true)
                        }
                    }
                }

                // BALANCE Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        CaptionText(NSLocalizedString("lightning__balance", comment: "").uppercased(), textColor: .textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        DetailRow(
                            label: NSLocalizedString("lightning__receiving_label", comment: ""),
                            value: "₿ \(formatNumber(channel.inboundCapacityMsat / 1000))", isFirst: true)
                        Divider().padding(.horizontal, 16)
                        DetailRow(
                            label: NSLocalizedString("lightning__spending_label", comment: ""),
                            value: "₿ \(formatNumber(channel.outboundCapacityMsat / 1000))")
                        Divider().padding(.horizontal, 16)
                        DetailRow(
                            label: NSLocalizedString("lightning__reserve_balance", comment: ""),
                            value: "₿ \(formatNumber(channel.unspendablePunishmentReserve ?? 0))")
                        Divider().padding(.horizontal, 16)
                        DetailRow(
                            label: NSLocalizedString("lightning__total_size", comment: ""), value: "₿ \(formatNumber(channel.channelValueSats))",
                            isLast: true)
                    }
                }

                // FEES Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        CaptionText(NSLocalizedString("lightning__fees", comment: "").uppercased(), textColor: .textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        DetailRow(label: NSLocalizedString("lightning__base_fee", comment: ""), value: "₿ 1", isFirst: true)
                        Divider().padding(.horizontal, 16)
                        DetailRow(label: "Receiving base fee", value: "₿ 1", isLast: true) // TODO: Add localization key for receiving base fee
                    }
                }

                // OTHER Section
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        CaptionText(NSLocalizedString("lightning__other", comment: "").uppercased(), textColor: .textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        let hasDate = isValidDate(linkedOrder?.createdAt)

                        if hasDate, let formattedDate = formatDate(linkedOrder?.createdAt ?? "") {
                            DetailRow(
                                label: NSLocalizedString("lightning__opened_on", comment: ""),
                                value: formattedDate,
                                isFirst: true)
                            Divider().padding(.horizontal, 16)
                            DetailRow(
                                label: NSLocalizedString("lightning__channel_node_id", comment: ""),
                                value: truncateString(channel.counterpartyNodeId.description, length: 16), isLast: true)
                        } else {
                            DetailRow(
                                label: NSLocalizedString("lightning__channel_node_id", comment: ""),
                                value: truncateString(channel.counterpartyNodeId.description, length: 16),
                                isFirst: true, isLast: true)
                        }
                    }
                }

                // Bottom buttons
                HStack(spacing: 16) {
                    CustomButton(
                        title: NSLocalizedString("lightning__support", comment: ""),
                        variant: .secondary,
                        shouldExpand: true
                    ) {
                        // Handle support action
                    }

                    if channelStatus == .open {
                        CustomButton(
                            title: NSLocalizedString("lightning__close_conn", comment: ""),
                            variant: .secondary,
                            shouldExpand: true
                        ) {
                            // Handle close connection action
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
            return NSLocalizedString("lightning__order_state__pending", comment: "").capitalized
        case .open:
            return NSLocalizedString("lightning__order_state__open", comment: "").capitalized
        case .closed:
            return NSLocalizedString("lightning__order_state__closed", comment: "").capitalized
        }
    }

    // Helper Views
    private func DetailRow(label: String, value: String, isFirst: Bool = false, isLast: Bool = false) -> some View {
        HStack {
            CaptionBText(label, textColor: .textPrimary)
            Spacer()
            CaptionBText(value, textColor: .white)
        }
        .padding(.horizontal, 16)
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
        guard let dateString = dateString, !dateString.isEmpty else { return false }
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
