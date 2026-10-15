import BitkitCore
import SwiftUI

struct UsdtActivityRow: View {
    let transfer: UsdtTransfer
    let hideBalance: Bool
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = PaykitFeatureFlags.uiEnabledByDefault
    @EnvironmentObject private var contacts: ContactsManager

    private var contactName: String? {
        guard PaykitFeatureFlags.isUIAvailable, isPaykitUIEnabled,
              let key = PaykitUsdtPaymentService.shared.contact(for: transfer.id) else { return nil }
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
            iconColor: transfer.activityIconColor,
            backgroundColor: transfer.activityIconColor.opacity(0.16),
            size: size
        )
    }
}

struct UsdtActivityDetail: View {
    let transferId: String
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = PaykitFeatureFlags.uiEnabledByDefault
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var contacts: ContactsManager
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: transfer?.detailTitle ?? t("usdt__sent_title"), titleKerning: 0, titleLineHeight: 26, onBack: { dismiss() })
                .padding(.bottom, 16)
            if let transfer {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        UsdtActivityAmountHeader(amount: transfer.activityAmount, isIncoming: transfer.isIncoming,
                                                 hideBalance: settings.hideBalance)
                            .padding(.bottom, 16)
                        if showDetails {
                            technicalDetails(transfer)
                        } else {
                            summary(transfer)
                        }
                        CustomButton(
                            title: t(showDetails ? "common__hide_details" : "wallet__send_details"), size: .small,
                            icon: Image(showDetails ? "eye-slash" : "git-branch").resizable().frame(width: 16, height: 16)
                                .foregroundColor(.usdtAccent), shouldExpand: true, titleKerning: 0, titleLineHeight: 13
                        ) { showDetails.toggle() }
                            .accessibilityIdentifier("UsdtActivityDetails")
                        if showDetails, let txHash = transfer.txHash {
                            if transfer.destination != .arbitrum, transfer.orchestra == nil {
                                CustomButton(title: t("usdt__track_bridge"), variant: .secondary, shouldExpand: true) {
                                    if let url = URL(string: "https://layerzeroscan.com/tx/" + txHash) { openURL(url) }
                                }
                            }
                        }
                        if showDetails, transfer.isIncoming, usdt.depositsConfigured, let txHash = transfer.txHash {
                            CustomButton(title: t("wallet__activity_explorer"), variant: .secondary, shouldExpand: true) {
                                if let url = URL(string: "https://arbiscan.io/tx/" + txHash) { openURL(url) }
                            }
                            .accessibilityIdentifier("UsdtActivityExplorer")
                        }
                        if transfer.destination != .arbitrum,
                           showDetails || transfer.needsBridgeSupport { UsdtSupportActions(details: transfer.supportDetails) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                if showDetails, transfer.isIncoming, usdt.depositsConfigured {
                    CustomButton(title: t("usdt__deposit_history"), shouldExpand: true, titleKerning: -0.4, titleLineHeight: 20) {
                        navigation.navigate(.usdtDepositHistory)
                    }
                    .padding(.top, 24)
                    .accessibilityIdentifier("UsdtDepositHistory")
                } else if showDetails, let txHash = transfer.txHash {
                    CustomButton(title: t("wallet__activity_explorer"), shouldExpand: true, titleKerning: -0.4, titleLineHeight: 20) {
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
                           icon: transfer.status == .confirmed ? "check-circle" : transfer.statusIcon,
                           valueColor: transfer.statusColor, iconColor: transfer.statusColor, valueKerning: 0)
                .accessibilityIdentifier("UsdtActivityStatus")
            UsdtDetailCell(title: t("usdt__receiving_network"), value: transfer.destination.label, icon: "usdt-network")
        }
        let time = DateFormatterHelpers.formatActivityDetail(transfer.timestamp)
        HStack(alignment: .top, spacing: 16) {
            UsdtDetailCell(title: t("wallet__activity_date"), value: time.date, icon: "calendar", valueKerning: 0)
            UsdtDetailCell(title: t("wallet__activity_time"), value: time.time, icon: "clock")
        }
        HStack(alignment: .top, spacing: 16) {
            UsdtDetailCell(title: t("wallet__activity_payment"), value: displayedAmount(transfer.amount), icon: "user")
            UsdtDetailCell(title: t("wallet__activity_fee"), value: transfer.fee.map(displayedAmount) ?? "—", icon: "speed-normal")
        }
        if PaykitFeatureFlags.isUIAvailable, isPaykitUIEnabled, let key = PaykitUsdtPaymentService.shared.contact(for: transfer.id) {
            SendSectionView(t("wallet__payment_request_contact"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                BodySSBText(contacts.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, key) }?.displayName
                    ?? PubkyPublicKeyFormat.displayTruncated(key), lineHeight: 20)
            }
        }
    }

    @ViewBuilder
    private func technicalDetails(_ transfer: UsdtTransfer) -> some View {
        if let txHash = transfer.txHash {
            SendSectionView(t("wallet__activity_tx_id"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                BodySSBText(txHash, kerning: 0, lineHeight: 20).textSelection(.enabled)
            }
        }
        if let sender = transfer.sender ?? (!transfer.isIncoming && !usdt.address.isEmpty ? usdt.address : nil) {
            SendSectionView(t("usdt__from_address"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                BodySSBText(sender, kerning: 0, lineHeight: 20).textSelection(.enabled)
            }
        }
        SendSectionView(t("usdt__to_address"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
            BodySSBText(transfer.recipient, kerning: 0, lineHeight: 20).textSelection(.enabled)
        }
        HStack(alignment: .top, spacing: 16) {
            if !transfer.isIncoming {
                UsdtDetailCell(title: t("usdt__sender_network"), value: UsdtDestination.arbitrum.label, icon: "usdt-network")
            }
            UsdtDetailCell(title: t("usdt__destination"), value: transfer.destination.label, icon: "usdt-network")
        }
        if let bridge = transfer.orchestra {
            UsdtDetailCell(title: t("usdt__bridge_provider"), value: "Orchestra", icon: "arrow-up-down")
            UsdtDetailCell(title: t("usdt__bridge_reference"), value: bridge.quoteId, icon: "note")
                .textSelection(.enabled)
            if let hash = bridge.destinationTx {
                SendSectionView(t("usdt__destination_tx"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                    BodySSBText(hash, kerning: 0, lineHeight: 20).textSelection(.enabled)
                }
            }
            if let amount = bridge.refundAmount, let hash = bridge.refundTx {
                SendSectionView(t("usdt__deposit_refunded"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) { amountText(amount) }
                SendSectionView(t("usdt__refund_tx"), dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
                    BodySSBText(hash, kerning: 0, lineHeight: 20).textSelection(.enabled)
                }
            }
        }
        if transfer.destination != .arbitrum, ![.failed, .replaced, .bridgeRefunded].contains(transfer.status) {
            SendSectionView(
                t(transfer.status == .confirmed ? "usdt__recipient_gets" : "usdt__expected_amount"),
                dividerSpacing: 15, labelKerning: 1,
                labelLineHeight: 18
            ) {
                amountText(transfer.receivedAmount)
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
        BodySSBText((settings.hideBalance ? " • • • • •" : usdtOverviewAmount(amount)) + " USDT", lineHeight: 20)
    }
}

extension UsdtTransfer {
    var detailTitle: String {
        if isIncoming { return t(status == .pending ? "usdt__receiving_title" : "usdt__payment_received") }
        return t(status == .bridging ? "usdt__delivering_title" : "usdt__sent_title")
    }

    var needsBridgeSupport: Bool {
        destination != .arbitrum && [.bridgeNeedsAttention, .bridgeFailed, .bridgeRefunded, .failed, .replaced].contains(status)
    }

    var activityAmount: UInt64 {
        if isIncoming { return amount }
        if status == .failed || status == .replaced { return fee ?? 0 }
        let total = amount.addingReportingOverflow(fee ?? 0)
        return total.overflow ? UInt64.max : total.partialValue
    }

    var title: String {
        switch status {
        case .failed, .replaced: status.label
        case .bridging: status.label
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
        case .bridging: "transfer"
        case .confirmed: isIncoming ? "arrow-down" : "arrow-up"
        case .bridgeRefunded: "arrow-down"
        }
    }

    var activityIconColor: Color {
        switch status {
        case .failed, .replaced, .bridgeFailed: .redAccent
        case .pending, .bridgeNeedsAttention: .yellowAccent
        default: .usdtAccent
        }
    }

    var statusColor: Color {
        switch status {
        case .failed, .replaced: .redAccent
        case .pending, .bridging, .bridgeNeedsAttention, .bridgeFailed: .yellowAccent
        default: .usdtAccent
        }
    }
}

struct UsdtDetailCell: View {
    let title: String
    let value: String
    let icon: String
    var valueColor: Color = .textPrimary
    var iconColor: Color = .usdtAccent
    var valueKerning: CGFloat = 0.4
    var minimumValueHeight: CGFloat = 20

    var body: some View {
        SendSectionView(title, dividerSpacing: 15, labelKerning: 1, labelLineHeight: 18) {
            HStack(spacing: 4) {
                Image(icon).resizable().scaledToFit().frame(width: 16, height: 16).foregroundColor(iconColor)
                BodySSBText(value, textColor: valueColor, kerning: valueKerning, lineHeight: 20)
            }
            .frame(minHeight: 20, alignment: .leading)
            .frame(minHeight: minimumValueHeight, alignment: .topLeading)
        }
    }
}

struct UsdtActivityAmountHeader: View {
    let amount: UInt64?
    let isIncoming: Bool
    let hideBalance: Bool

    private var displayedAmount: String {
        hideBalance ? "• • • • •" : amount.map { usdtOverviewAmount($0) } ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CaptionMText(hideBalance ? displayedAmount : "$ " + displayedAmount, kerning: 1, lineHeight: 18)
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    DisplayText("<accent>\(isIncoming ? "+" : "-")</accent>",
                                accentColor: .textSecondary, accentFont: Fonts.extraBold, fillsWidth: false, lineHeight: 44)
                    DisplayText(displayedAmount, lineHeight: 44).lineLimit(1).minimumScaleFactor(0.5)
                }
                CircularIcon(icon: isIncoming ? "arrow-down" : "arrow-up", iconColor: .usdtAccent,
                             backgroundColor: .usdtAccent.opacity(0.16), size: 48)
            }
            .frame(height: 36)
        }
    }
}
