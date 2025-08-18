import BitkitCore
import SwiftUI

private struct TransactionStatusText: View {
    let txType: PaymentType
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?

    init(txType: PaymentType, activity: Activity) {
        self.txType = txType
        switch activity {
        case let .lightning(ln):
            isLightning = true
            status = ln.status
            confirmed = nil
        case let .onchain(onchain):
            isLightning = false
            status = nil
            confirmed = onchain.confirmed
        }
    }

    var body: some View {
        if isLightning {
            lightningStatus
        } else {
            onchainStatus
        }
    }

    @ViewBuilder
    private var lightningStatus: some View {
        if txType == .sent {
            switch status {
            case .failed:
                BodyMSBText(t("wallet__activity_failed"), textColor: .textPrimary)
            case .pending:
                BodyMSBText(t("wallet__activity_pending"), textColor: .textPrimary)
            case .succeeded:
                BodyMSBText(t("wallet__activity_sent"), textColor: .textPrimary)
            case .none:
                EmptyView()
            }
        } else {
            switch status {
            case .failed:
                BodyMSBText(t("wallet__activity_failed"), textColor: .textPrimary)
            case .pending:
                BodyMSBText(t("wallet__activity_pending"), textColor: .textPrimary)
            case .succeeded:
                BodyMSBText(t("wallet__activity_received"), textColor: .textPrimary)
            case .none:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var onchainStatus: some View {
        if txType == .sent {
            BodyMSBText(t("wallet__activity_sent"), textColor: .textPrimary)
        } else {
            BodyMSBText(t("wallet__activity_received"), textColor: .textPrimary)
        }
    }
}

struct ActivityRow: View {
    let item: Activity
    @EnvironmentObject var currency: CurrencyViewModel

    private var formattedTime: String {
        let timestamp = switch item {
        case let .lightning(activity):
            TimeInterval(activity.timestamp)
        case let .onchain(activity):
            TimeInterval(activity.timestamp)
        }

        return DateFormatterHelpers.formatActivityTime(UInt64(timestamp))
    }

    private var amountPrefix: String {
        switch item {
        case let .lightning(activity):
            return activity.txType == .sent ? "-" : "+"
        case let .onchain(activity):
            return activity.txType == .sent ? "-" : "+"
        }
    }

    @ViewBuilder
    private var amountView: some View {
        switch item {
        case let .lightning(activity):
            MoneyCell(sats: Int(activity.value), prefix: amountPrefix)
        case let .onchain(activity):
            MoneyCell(sats: Int(activity.value), prefix: amountPrefix)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                switch item {
                case let .lightning(activity):
                    TransactionStatusText(txType: activity.txType, activity: item)
                case let .onchain(activity):
                    TransactionStatusText(txType: activity.txType, activity: item)
                }

                // Show message if available, otherwise show time
                switch item {
                case let .lightning(activity):
                    if !activity.message.isEmpty {
                        CaptionBText(activity.message)
                    } else {
                        CaptionBText(formattedTime)
                    }
                case .onchain:
                    CaptionBText(formattedTime)
                }
            }

            Spacer()
            amountView
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    var icon: some View {
        ActivityIcon(activity: item, size: 32)
    }
}
