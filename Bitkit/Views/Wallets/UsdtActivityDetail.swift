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
                subtitle: DateFormatterHelpers.getActivityItemDate(transfer.timestamp)
            ) {
                UsdtActivityIcon(transfer: transfer)
            } amount: {
                VStack(alignment: .trailing, spacing: 2) {
                    BodyMSBText(
                        "<accent>\(transfer.isIncoming ? "+" : "−")</accent> "
                            + (hideBalance ? " • • • • •" : usdtFormatAmount(amount: transfer.activityAmount)),
                        accentColor: .textSecondary
                    )
                    .lineLimit(1).minimumScaleFactor(0.7)
                    CaptionBText("USDT", textColor: .textSecondary)
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
            iconColor: transfer.statusColor,
            backgroundColor: transfer.statusColor.opacity(0.16),
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: transfer?.title ?? t("usdt__activity"), onBack: { dismiss() }).padding(.bottom, 16)
            if let transfer {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .bottom) {
                            UsdtAmountHeader(
                                amount: usdtFormatAmount(amount: transfer.activityAmount), network: transfer.destination.label,
                                prefix: transfer.isIncoming ? "+ " : "− ", hideBalance: settings.hideBalance
                            )
                            UsdtActivityIcon(transfer: transfer, size: 48)
                        }
                        .padding(.bottom, 16)
                        SendSectionView(t("wallet__activity_status")) {
                            Label {
                                BodySSBText(transfer.status.label, textColor: transfer.statusColor)
                            } icon: {
                                Image(transfer.statusIcon).foregroundColor(transfer.statusColor)
                            }
                            .accessibilityIdentifier("UsdtActivityStatus")
                        }
                        let time = DateFormatterHelpers.formatActivityDetail(transfer.timestamp)
                        HStack(spacing: 16) {
                            SendSectionView(t("wallet__activity_date")) { BodySSBText(time.date) }
                            SendSectionView(t("wallet__activity_time")) { BodySSBText(time.time) }
                        }
                        if let key = PaykitUsdtPaymentService.shared.contact(for: transfer.id) {
                            SendSectionView(t(transfer.isIncoming ? "wallet__send_from" : "wallet__send_to")) {
                                BodySSBText(contacts.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, key) }?.displayName
                                    ?? PubkyPublicKeyFormat.displayTruncated(key))
                            }
                        }
                        SendSectionView(t("usdt__destination")) { BodySSBText(transfer.destination.label) }
                        if !transfer.isIncoming {
                            SendSectionView(t("usdt__address")) { BodySSBText(transfer.recipient).textSelection(.enabled) }
                            HStack(alignment: .top, spacing: 16) {
                                if transfer.status != .failed, transfer.status != .replaced {
                                    SendSectionView(t(transfer.destination != .arbitrum && transfer.status != .confirmed
                                            ? "usdt__expected_amount" : "usdt__recipient_gets")) { amountText(transfer.receivedAmount) }
                                }
                                SendSectionView(t("wallet__activity_fee")) {
                                    if let fee = transfer.fee {
                                        amountText(fee)
                                    } else { BodySSBText("—") }
                                }
                            }
                        }
                        if let bridge = transfer.orchestra {
                            SendSectionView(t("usdt__bridge_provider")) { BodySSBText("Orchestra") }
                            SendSectionView(t("usdt__bridge_reference")) { BodySText(bridge.quoteId).textSelection(.enabled) }
                            if let hash = bridge.destinationTx {
                                SendSectionView(t("usdt__destination_tx")) { BodySText(hash).textSelection(.enabled) }
                            }
                            if let amount = bridge.refundAmount, let hash = bridge.refundTx {
                                SendSectionView(t("usdt__deposit_refunded")) { amountText(amount) }
                                SendSectionView(t("usdt__refund_tx")) { BodySText(hash).textSelection(.enabled) }
                            }
                        }
                        if let txHash = transfer.txHash {
                            SendSectionView(t("wallet__activity_tx_id")) { BodySText(txHash).textSelection(.enabled) }
                            if transfer.destination != .arbitrum, transfer.orchestra == nil {
                                CustomButton(title: t("usdt__track_bridge"), variant: .secondary, shouldExpand: true) {
                                    if let url = URL(string: "https://layerzeroscan.com/tx/" + txHash) { openURL(url) }
                                }
                            }
                            if let url = URL(string: "https://arbiscan.io/tx/" + txHash) {
                                CustomButton(title: t("wallet__activity_explore"), variant: .secondary, shouldExpand: true) { openURL(url) }
                            }
                        }
                        if transfer.destination != .arbitrum {
                            UsdtSupportActions(details: transfer.supportDetails)
                        }
                    }
                    .bottomSafeAreaPadding()
                }
            }
        }
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await usdt.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    private var transfer: UsdtTransfer? {
        usdt.transfers.first { $0.id == transferId }
    }

    private func amountText(_ amount: UInt64) -> some View {
        BodySSBText((settings.hideBalance ? " • • • • •" : usdtFormatAmount(amount: amount)) + " USDT")
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
        case .pending, .bridging, .bridgeNeedsAttention, .bridgeFailed, .bridgeRefunded: status.label
        default: t(isIncoming ? "usdt__received" : "usdt__sent")
        }
    }

    var groupTitle: String {
        DateFormatterHelpers.getActivityGroupHeader(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    var statusIcon: String {
        switch status {
        case .failed, .replaced, .bridgeFailed: "x-mark"
        case .pending, .bridging, .bridgeNeedsAttention: "hourglass-simple"
        case .confirmed: isIncoming ? "arrow-down" : "arrow-up"
        case .bridgeRefunded: "arrow-down"
        }
    }

    var statusColor: Color {
        switch status {
        case .failed, .replaced: .redAccent
        case .bridgeNeedsAttention, .bridgeFailed: .yellowAccent
        default: .greenAccent
        }
    }
}
