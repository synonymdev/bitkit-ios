import BitkitCore
import SwiftUI

struct UsdtActivityRow: View {
    let transfer: UsdtTransfer
    let hideBalance: Bool
    @EnvironmentObject private var contacts: ContactsManager

    private var contactName: String? {
        guard let key = PaykitUsdtPaymentService.shared.contact(for: transfer.id) else { return nil }
        return contacts.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, key) }?.displayName ?? PubkyPublicKeyFormat.displayTruncated(key)
    }

    var body: some View {
        ActivityRowContainer {
            ActivityRowContent(
                title: contactName ?? transfer.title,
                subtitle: transfer.status == .bridging
                    ? t("usdt__to_network", variables: ["network": transfer.destination.label])
                    : DateFormatterHelpers.getActivityItemDate(transfer.timestamp)
            ) {
                UsdtActivityIcon(transfer: transfer)
            } amount: {
                VStack(alignment: .trailing, spacing: 2) {
                    BodyMSBText(
                        "<accent>\(transfer.isIncoming ? "+" : "−")</accent> "
                            + (hideBalance ? " • • • • •" : usdtOverviewAmount(transfer.activityAmount)),
                        accentColor: .textSecondary
                    )
                    .lineLimit(1).minimumScaleFactor(0.7)
                    CaptionBText(hideBalance ? "• • • • •" : "$ " + usdtOverviewAmount(transfer.activityAmount), textColor: .textSecondary)
                }
            }
        }
    }
}

struct UsdtActivityIcon: View {
    let transfer: UsdtTransfer
    var size: CGFloat = 40

    var body: some View {
        CircularIcon(
            icon: transfer.statusIcon,
            iconColor: .usdtAccent,
            backgroundColor: Color.usdtAccent.opacity(0.16),
            size: size
        )
    }
}

struct UsdtActivityDetail: View {
    let transferId: String
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var contacts: ContactsManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t(transfer?.isIncoming == true ? "usdt__payment_received" : "usdt__sent_title"), onBack: { dismiss() })
                .padding(.bottom, 16)
            if let transfer {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            CaptionMText(settings.hideBalance ? "• • • • •" : "$ " + usdtOverviewAmount(transfer.activityAmount))
                            HStack(spacing: 16) {
                                DisplayText(
                                    "<accent>\(transfer.isIncoming ? "+" : "−")</accent> "
                                        + (settings.hideBalance ? "• • • • •" : usdtOverviewAmount(transfer.activityAmount)),
                                    accentColor: .textSecondary, accentFont: Fonts.extraBold
                                ).lineLimit(1).minimumScaleFactor(0.5)
                                UsdtActivityIcon(transfer: transfer, size: 48)
                            }
                            .frame(height: 36)
                        }.padding(.bottom, 16)
                        if showDetails {
                            technicalDetails(transfer)
                        } else {
                            summary(transfer)
                        }
                        CustomButton(
                            title: t(showDetails ? "common__hide_details" : "wallet__send_details"), size: .small,
                            icon: Image(showDetails ? "eye-slash" : "git-branch").resizable().frame(width: 16, height: 16)
                                .foregroundColor(.usdtAccent), shouldExpand: true
                        ) { showDetails.toggle() }
                            .accessibilityIdentifier("UsdtActivityDetails")
                        if showDetails, let txHash = transfer.txHash {
                            if transfer.destination != .arbitrum, transfer.orchestra == nil {
                                CustomButton(title: t("usdt__track_bridge"), variant: .secondary, shouldExpand: true) {
                                    if let url = URL(string: "https://layerzeroscan.com/tx/" + txHash) { openURL(url) }
                                }
                            }
                        }
                        if transfer.destination != .arbitrum { UsdtSupportActions(details: transfer.supportDetails) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                if showDetails, let txHash = transfer.txHash {
                    CustomButton(title: t("wallet__activity_explorer"), shouldExpand: true) {
                        if let url = URL(string: "https://arbiscan.io/tx/" + txHash) { openURL(url) }
                    }
                    .padding(.top, 24)
                    .accessibilityIdentifier("UsdtActivityExplorer")
                }
            }
        }
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .navigationBarHidden(true)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await usdt.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    @ViewBuilder
    private func summary(_ transfer: UsdtTransfer) -> some View {
        HStack(alignment: .top, spacing: 16) {
            UsdtDetailCell(title: t("wallet__activity_status"), value: transfer.status.label,
                           icon: transfer.status == .confirmed ? "check-circle" : transfer.statusIcon, valueColor: transfer.statusColor)
                .accessibilityIdentifier("UsdtActivityStatus")
            UsdtDetailCell(title: t("usdt__network"), value: UsdtDestination.arbitrum.label, icon: "usdt-network")
        }
        let time = DateFormatterHelpers.formatActivityDetail(transfer.timestamp)
        HStack(alignment: .top, spacing: 16) {
            UsdtDetailCell(title: t("wallet__activity_date"), value: time.date, icon: "calendar")
            UsdtDetailCell(title: t("wallet__activity_time"), value: time.time, icon: "clock")
        }
        HStack(alignment: .top, spacing: 16) {
            UsdtDetailCell(title: t("wallet__activity_payment"), value: displayedAmount(transfer.amount), icon: "user")
            UsdtDetailCell(title: t("wallet__activity_fee"), value: transfer.fee.map(displayedAmount) ?? "—", icon: "speed-normal")
        }
        if let key = PaykitUsdtPaymentService.shared.contact(for: transfer.id) {
            SendSectionView(t("wallet__payment_request_contact")) {
                BodySSBText(contacts.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, key) }?.displayName
                    ?? PubkyPublicKeyFormat.displayTruncated(key))
            }
        }
        if transfer.destination != .arbitrum, transfer.status != .failed, transfer.status != .replaced {
            SendSectionView(t(transfer.status == .confirmed ? "usdt__recipient_gets" : "usdt__expected_amount")) {
                amountText(transfer.receivedAmount)
            }
        }
    }

    @ViewBuilder
    private func technicalDetails(_ transfer: UsdtTransfer) -> some View {
        if let txHash = transfer.txHash {
            SendSectionView(t("wallet__activity_tx_id")) { BodySSBText(txHash).textSelection(.enabled) }
        }
        if let sender = transfer.sender ?? (!transfer.isIncoming && !usdt.address.isEmpty ? usdt.address : nil) {
            SendSectionView(t("usdt__from_address")) { BodySSBText(sender).textSelection(.enabled) }
        }
        SendSectionView(t("usdt__to_address")) { BodySSBText(transfer.recipient).textSelection(.enabled) }
        HStack(alignment: .top, spacing: 16) {
            if !transfer.isIncoming {
                UsdtDetailCell(title: t("usdt__sender_network"), value: UsdtDestination.arbitrum.label, icon: "usdt-network")
            }
            UsdtDetailCell(title: t("usdt__destination"), value: transfer.destination.label, icon: "usdt-network")
        }
        if let bridge = transfer.orchestra {
            SendSectionView(t("usdt__bridge_provider")) { BodySSBText("Orchestra") }
            SendSectionView(t("usdt__bridge_reference")) { BodySSBText(bridge.quoteId).textSelection(.enabled) }
            if let hash = bridge.destinationTx {
                SendSectionView(t("usdt__destination_tx")) { BodySSBText(hash).textSelection(.enabled) }
            }
            if let amount = bridge.refundAmount, let hash = bridge.refundTx {
                SendSectionView(t("usdt__deposit_refunded")) { amountText(amount) }
                SendSectionView(t("usdt__refund_tx")) { BodySSBText(hash).textSelection(.enabled) }
            }
        }
    }

    private func displayedAmount(_ amount: UInt64) -> String {
        settings.hideBalance ? "• • • • •" : usdtOverviewAmount(amount)
    }

    private var transfer: UsdtTransfer? {
        usdt.transfers.first { $0.id == transferId }
    }

    private func amountText(_ amount: UInt64) -> some View {
        BodySSBText((settings.hideBalance ? " • • • • •" : usdtOverviewAmount(amount)) + " USDT")
    }
}

extension UsdtTransfer {
    var activityAmount: UInt64 {
        if isIncoming { return amount }
        if status == .failed || status == .replaced { return fee ?? 0 }
        let total = amount.addingReportingOverflow(fee ?? 0)
        return total.overflow ? UInt64.max : total.partialValue
    }

    var title: String {
        switch status {
        case .failed, .replaced: status.label
        case .bridging: t("wallet__activity_transferring")
        case .pending, .bridgeNeedsAttention, .bridgeFailed, .bridgeRefunded: status.label
        default: t(isIncoming ? "usdt__received" : "usdt__sent")
        }
    }

    var groupTitle: String {
        DateFormatterHelpers.getActivityGroupHeader(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    var statusIcon: String {
        switch status {
        case .failed, .replaced, .bridgeFailed: "x-circle"
        case .pending, .bridgeNeedsAttention: "hourglass-simple"
        case .bridging: "arrow-up-down"
        case .confirmed: isIncoming ? "arrow-down" : "arrow-up"
        case .bridgeRefunded: "arrow-down"
        }
    }

    var statusColor: Color {
        switch status {
        case .failed, .replaced: .redAccent
        case .bridgeNeedsAttention, .bridgeFailed: .yellowAccent
        default: .usdtAccent
        }
    }
}

struct UsdtDetailCell: View {
    let title: String
    let value: String
    let icon: String
    var valueColor: Color = .textPrimary
    var minimumValueHeight: CGFloat = 20

    var body: some View {
        SendSectionView(title) {
            HStack(spacing: 4) {
                Image(icon).resizable().scaledToFit().frame(width: 16, height: 16).foregroundColor(.usdtAccent)
                BodySSBText(value, textColor: valueColor)
            }
            .frame(minHeight: 20, alignment: .leading)
            .frame(minHeight: minimumValueHeight, alignment: .topLeading)
        }
    }
}
