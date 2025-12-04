import BitkitCore
import LDKNode
import SwiftUI

struct LightningConnectionDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var channelDetails: ChannelDetailsViewModel

    let channelId: String

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d, yyyy - HH:mm"
        return formatter
    }()

    private static let iso8601FormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__connection"))
                .padding(.bottom, 16)
                .task {
                    await channelDetails.findChannel(channelId: channelId, wallet: wallet)

                    // If channel not found after loading, show toast and go back
                    if !channelDetails.isLoading, channelDetails.foundChannel == nil {
                        app.toast(
                            type: .error,
                            title: t("lightning__connection_not_found_title"),
                            description: t("lightning__connection_not_found_message")
                        )
                        navigation.navigateBack()
                    }
                }

            GeometryReader { _ in
                ScrollView(showsIndicators: false) {
                    if let channel = channelDetails.foundChannel {
                        VStack(alignment: .leading, spacing: 0) {
                            LightningChannel(
                                capacity: channel.channelValueSats,
                                localBalance: channel.outboundCapacityMsat / 1000,
                                remoteBalance: channel.inboundCapacityMsat / 1000,
                                status: channel.isClosed ? .closed : channelStatus(for: channel)
                            )
                            .padding(.bottom, 28)

                            VStack(alignment: .leading, spacing: 32) {
                                // STATUS Section
                                VStack(alignment: .leading, spacing: 16) {
                                    Divider()

                                    CaptionMText(t("lightning__status"))

                                    HStack(alignment: .center, spacing: 8) {
                                        let status = detailedStatus(for: channel)
                                        CircularIcon(
                                            icon: status.icon,
                                            iconColor: status.color,
                                            backgroundColor: status.color.opacity(0.16),
                                            size: 32
                                        )

                                        BodyMSBText(status.text, textColor: status.color)
                                    }

                                    Divider()
                                }

                                // ORDER DETAILS Section
                                if let order = channelDetails.linkedOrder {
                                    VStack(alignment: .leading, spacing: 0) {
                                        CaptionMText(t("lightning__order_details"))
                                            .padding(.bottom, 16)

                                        DetailRow(label: t("lightning__order"), value: order.id)

                                        if let formattedDate = formatDate(order.createdAt) {
                                            DetailRow(label: t("lightning__created_on"), value: formattedDate)
                                        }

                                        if channelStatus(for: channel) == .pending {
                                            if let formattedExpiry = formatDate(order.orderExpiresAt) {
                                                DetailRow(label: t("lightning__order_expiry"), value: formattedExpiry)
                                            }
                                        }

                                        if channelStatus(for: channel) != .pending, let txid = channel.displayedFundingTxoTxid {
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
                                    DetailRowWithAmount(
                                        label: t("lightning__total_size"),
                                        amount: channel.channelValueSats,
                                        amountTestId: "TotalSize"
                                    )
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
                                        DetailRow(
                                            label: t("lightning__is_usable"),
                                            value: channel.isUsable ? t("common__yes") : t("common__no"),
                                            valueTestId: channel.isUsable ? "IsUsableYes" : "IsUsableNo"
                                        )

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
                            .padding(.bottom, 32)

                            // Bottom buttons
                            HStack(spacing: 16) {
                                CustomButton(title: t("lightning__support"), variant: .secondary) {
                                    // TODO: Handle support action
                                    navigation.navigate(Route.support)
                                }

                                if channelStatus(for: channel) == .open, let openChannel = channel as? ChannelDetails {
                                    CustomButton(title: t("lightning__close_conn")) {
                                        navigation.navigate(Route.closeConnection(channel: openChannel))
                                    }
                                    .accessibilityIdentifier("CloseConnection")
                                }
                            }
                        }
                    } else if channelDetails.isLoading {
                        // Loading state
                        VStack {
                            Spacer()
                            ActivityIndicator()
                            Spacer()
                        }
                    }
                }
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }

    // MARK: - Computed Properties

    private func channelStatus(for channel: ChannelDisplayable) -> ChannelStatus {
        if channel.isClosed {
            return .closed
        }
        if !channel.isChannelReady {
            return .pending
        }
        return .open
    }

    private func detailedStatus(for channel: ChannelDisplayable) -> (text: String, color: Color, icon: String) {
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

        if let order = channelDetails.linkedOrder {
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
    private func DetailRow(label: String, value: String, valueTestId: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 0) {
                    CaptionBText(label, textColor: .textPrimary)
                        .frame(width: geometry.size.width * 0.4, alignment: .leading)

                    CaptionBText(value, textColor: .textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: geometry.size.width * 0.6, alignment: .trailing)
                        .accessibilityIdentifierIfPresent(valueTestId)
                }
                .frame(height: 50)
            }

            Divider()
        }
        .frame(height: 51)
    }

    private func DetailRowWithAmount(label: String, amount: UInt64, amountTestId: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 0) {
                    CaptionBText(label, textColor: .textPrimary)
                        .frame(width: geometry.size.width * 0.4, alignment: .leading)

                    MoneyText(sats: Int(amount), size: .captionB, symbol: true)
                        .frame(width: geometry.size.width * 0.6, alignment: .trailing)
                        .accessibilityIdentifierIfPresent(amountTestId)
                }
                .frame(height: 50)
            }

            Divider()
        }
        .frame(height: 51)
    }

    private func formatDate(_ timestamp: UInt64) -> String? {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return Self.dateFormatter.string(from: date)
    }

    private func formatDate(_ dateString: String) -> String? {
        // Try ISO 8601 format with fractional seconds
        if let date = Self.iso8601FormatterWithFractionalSeconds.date(from: dateString) {
            return Self.dateFormatter.string(from: date)
        }

        // Try ISO 8601 format without fractional seconds
        if let date = Self.iso8601Formatter.date(from: dateString) {
            return Self.dateFormatter.string(from: date)
        }

        // Try simple date format as fallback
        if let date = Self.inputDateFormatter.date(from: dateString) {
            return Self.dateFormatter.string(from: date)
        }

        // Return nil if parsing fails
        return nil
    }
}
