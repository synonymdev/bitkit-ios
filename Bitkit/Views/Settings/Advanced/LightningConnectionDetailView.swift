import BitkitCore
import LDKNode
import SwiftUI

struct LightningConnectionDetailView: View {
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let channel: ChannelDisplayable
    let linkedOrder: IBtOrder?
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: title)
                .padding(.bottom, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LightningChannel(
                            capacity: channel.channelValueSats,
                            localBalance: channel.outboundCapacityMsat / 1000,
                            remoteBalance: channel.inboundCapacityMsat / 1000,
                            status: channel.isClosed ? .closed : channelStatus
                        )
                        .padding(.bottom, 28)

                        VStack(alignment: .leading, spacing: 32) {
                            // STATUS Section
                            VStack(alignment: .leading, spacing: 16) {
                                Divider()

                                CaptionMText(t("lightning__status"))

                                HStack(alignment: .center, spacing: 8) {
                                    CircularIcon(
                                        icon: detailedStatus.icon,
                                        iconColor: detailedStatus.color,
                                        backgroundColor: detailedStatus.color.opacity(0.16),
                                        size: 32
                                    )

                                    BodyMSBText(detailedStatus.text, textColor: detailedStatus.color)
                                }

                                Divider()
                            }

                            // ORDER DETAILS Section
                            if let order = linkedOrder {
                                VStack(alignment: .leading, spacing: 0) {
                                    CaptionMText(t("lightning__order_details"))
                                        .padding(.bottom, 16)

                                    DetailRow(label: t("lightning__order"), value: order.id)

                                    if let formattedDate = formatDate(order.createdAt) {
                                        DetailRow(label: t("lightning__created_on"), value: formattedDate)
                                    }

                                    if channelStatus == .pending {
                                        if let formattedExpiry = formatDate(order.orderExpiresAt) {
                                            DetailRow(label: t("lightning__order_expiry"), value: formattedExpiry)
                                        }
                                    }

                                    if channelStatus != .pending, let txid = channel.displayedFundingTxoTxid {
                                        DetailRow(label: t("lightning__transaction"), value: txid)
                                    }

                                    DetailRowWithAmount(label: t("lightning__order_fee"), amount: order.feeSat - order.clientBalanceSat)
                                }
                            }

                            // BALANCE Section
                            VStack(alignment: .leading, spacing: 0) {
                                CaptionMText(t("lightning__balance"))
                                    .padding(.bottom, 16)

                                DetailRowWithAmount(
                                    label: t("lightning__receiving_label"),
                                    amount: channel.inboundCapacityMsat / 1000
                                )
                                DetailRowWithAmount(
                                    label: t("lightning__spending_label"),
                                    amount: channel.outboundCapacityMsat / 1000
                                )
                                DetailRowWithAmount(
                                    label: t("lightning__reserve_balance"),
                                    amount: channel.displayedUnspendablePunishmentReserve
                                )
                                DetailRowWithAmount(label: t("lightning__total_size"), amount: channel.channelValueSats)
                            }

                            // FEES Section
                            VStack(alignment: .leading, spacing: 0) {
                                CaptionMText(t("lightning__fees"))
                                    .padding(.bottom, 16)

                                DetailRowWithAmount(label: t("lightning__base_fee"), amount: UInt64(channel.forwardingFeeBaseMsat / 1000))
                                DetailRow(label: t("lightning__fee_rate"), value: "\(channel.forwardingFeeProportionalMillionths) ppm")
                            }

                            // OTHER Section
                            VStack(alignment: .leading, spacing: 16) {
                                CaptionMText(t("lightning__other"))

                                VStack(spacing: 0) {
                                    DetailRow(label: t("lightning__is_usable"), value: channel.isUsable ? t("common__yes") : t("common__no"))

                                    // TODO: Add channel opening date
                                    // if let formattedDate = formatDate(channel.fundingTxo) {
                                    //     DetailRow(label: t("lightning__opened_on"), value: formattedDate)
                                    // }

                                    if let closedAt = channel.displayedClosedAt {
                                        if let formattedCloseDate = formatDate(closedAt) {
                                            DetailRow(label: t("lightning__closed_on"), value: formattedCloseDate)
                                        }
                                    }

                                    DetailRow(label: t("lightning__channel_id"), value: channel.channelIdString)

                                    if let txid = channel.displayedFundingTxoTxid, let vout = channel.fundingTxoVout {
                                        DetailRow(label: t("lightning__channel_point"), value: "\(txid):\(vout)")
                                    }

                                    DetailRow(
                                        label: t("lightning__channel_node_id"),
                                        value: channel.counterpartyNodeIdString
                                    )

                                    if let reason = channel.closureReason {
                                        DetailRow(label: t("lightning__closure_reason"), value: reason)
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 32)

                        // Bottom buttons
                        HStack(spacing: 16) {
                            CustomButton(title: t("lightning__support"), variant: .secondary) {
                                // TODO: Handle support action
                                navigation.navigate(Route.support)
                            }

                            if channelStatus == .open, let openChannel = channel as? ChannelDetails {
                                CustomButton(title: t("lightning__close_conn")) {
                                    navigation.navigate(Route.closeConnection(channel: openChannel))
                                }
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
    }

    // MARK: - Computed Properties

    private var channelStatus: ChannelStatus {
        if channel.isClosed {
            return .closed
        }
        if !channel.isChannelReady {
            return .pending
        }
        return .open
    }

    private var detailedStatus: (text: String, color: Color, icon: String) {
        // Handle closed channels
        if channel.isClosed {
            return (
                text: t("lightning__conn_closed"),
                color: .textSecondary,
                icon: "bolt"
            )
        }

        // Use open/closed status from LDK if available
        if channel.isChannelReady {
            if !channel.isUsable {
                return (
                    text: t("lightning__order_state__inactive"),
                    color: .yellowAccent,
                    icon: "bolt"
                )
            }
            return (
                text: t("lightning__order_state__open"),
                color: .greenAccent,
                icon: "bolt"
            )
        }

        if let order = linkedOrder {
            // If the channel is with the LSP, we can show a more accurate status for pending channels
            let orderState = order.state2
            let paymentState = order.payment?.state2
            let channelState = order.channel?.state

            if let channelState {
                switch channelState {
                case .opening:
                    return (
                        text: t("lightning__order_state__opening"),
                        color: .purpleAccent,
                        icon: "hourglass-simple"
                    )
                default:
                    break
                }
            }

            switch orderState {
            case .expired:
                return (
                    text: t("lightning__order_state__expired"),
                    color: .redAccent,
                    icon: "timer-speed"
                )
            default:
                break
            }

            switch paymentState {
            case nil:
                return (
                    text: t("lightning__order_state__awaiting_payment"),
                    color: .purpleAccent,
                    icon: "clock"
                )
            case .canceled:
                return (
                    text: t("lightning__order_state__payment_canceled"),
                    color: .redAccent,
                    icon: "x-mark"
                )
            case .refundAvailable:
                return (
                    text: t("lightning__order_state__refund_available"),
                    color: .yellowAccent,
                    icon: "arrow-counter-clock"
                )
            case .refunded:
                return (
                    text: t("lightning__order_state__refunded"),
                    color: .textSecondary,
                    icon: "arrow-counter-clock"
                )
            case .created:
                return (
                    text: t("lightning__order_state__awaiting_payment"),
                    color: .purpleAccent,
                    icon: "clock"
                )
            case .paid:
                return (
                    text: t("lightning__order_state__paid"),
                    color: .purpleAccent,
                    icon: "checkmark"
                )
            }
        }

        // Fallback for pending channels without order info
        return (
            text: t("lightning__order_state__opening"),
            color: .purpleAccent,
            icon: "hourglass-simple"
        )
    }

    // Helper Views
    private func DetailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 0) {
                    CaptionBText(label, textColor: .textPrimary)
                        .frame(width: geometry.size.width * 0.4, alignment: .leading)

                    CaptionBText(value, textColor: .textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: geometry.size.width * 0.6, alignment: .trailing)
                }
                .frame(height: 50)
            }

            Divider()
        }
        .frame(height: 51)
    }

    private func DetailRowWithAmount(label: String, amount: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 0) {
                    CaptionBText(label, textColor: .textPrimary)
                        .frame(width: geometry.size.width * 0.4, alignment: .leading)

                    MoneyText(sats: Int(amount), size: .captionB, symbol: true)
                        .frame(width: geometry.size.width * 0.6, alignment: .trailing)
                }
                .frame(height: 50)
            }

            Divider()
        }
        .frame(height: 51)
    }

    private func formatDate(_ timestamp: UInt64) -> String? {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy - HH:mm"
        return formatter.string(from: date)
    }

    private func formatDate(_ dateString: String) -> String? {
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MMM d, yyyy - HH:mm"

        // Try ISO 8601 format with fractional seconds
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: dateString) {
            return outputFormatter.string(from: date)
        }

        // Try ISO 8601 format without fractional seconds
        let isoFormatter2 = ISO8601DateFormatter()
        isoFormatter2.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter2.date(from: dateString) {
            return outputFormatter.string(from: date)
        }

        // Try simple date format as fallback
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"
        if let date = inputFormatter.date(from: dateString) {
            return outputFormatter.string(from: date)
        }

        // Return nil if parsing fails
        return nil
    }
}
