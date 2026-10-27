import BitkitCore
import SwiftUI

/// One Spark dollar activity: a transfer, a conversion with its bitcoin side, or a move to USDT.
struct SparkUsdActivityDetail: View {
    let transferId: String
    @EnvironmentObject private var settings: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    private let spark = SparkManager.shared

    private var transfer: SparkUsdTransfer? {
        spark.usd?.transfers.first { $0.id == transferId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: transfer?.title ?? "", titleKerning: 0, titleLineHeight: 26, onBack: { dismiss() })
            if let transfer {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center) {
                            UsdtAmountHeader(
                                amount: usdtFormatAmount(amount: transfer.amount),
                                displayAmount: usdtOverviewAmount(transfer.amount),
                                prefix: transfer.isIncoming ? "+" : "−",
                                hideBalance: settings.hideBalance
                            )
                            .accessibilityIdentifier("SparkUsdActivityAmount")
                            CircularIcon(
                                icon: transfer.statusIcon,
                                iconColor: transfer.iconColor,
                                backgroundColor: transfer.iconColor.opacity(0.16),
                                size: 40
                            )
                        }
                        .padding(.vertical, 16)
                        detailRow(t("wallet__activity_status"), transfer.statusLabel)
                        detailRow(t("wallet__activity_date"), DateFormatterHelpers.getActivityItemDate(transfer.timestamp))
                        if let sats = transfer.sats {
                            detailRow(t(transfer.isIncoming ? "wallet__activity_sent" : "wallet__activity_received"), "₿ " + sats.formatted())
                        }
                        detailRow(t("wallet__activity_fee"), "$ " + usdtOverviewAmount(transfer.fee))
                        if let counterparty = transfer.counterparty {
                            detailRow(t("wallet__activity_invoice"), counterparty)
                        }
                        if let txHash = transfer.txHash {
                            detailRow(t("wallet__activity_tx_id"), txHash)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(label)
            BodySSBText(value, kerning: 0).lineLimit(3)
            CustomDivider().padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}
