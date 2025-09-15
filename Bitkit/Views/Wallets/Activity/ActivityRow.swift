import BitkitCore
import SwiftUI

private struct TransactionStatusText: View {
    let txType: PaymentType
    let isLightning: Bool
    let status: PaymentState?
    let confirmed: Bool?
    let isTransfer: Bool

    init(txType: PaymentType, activity: Activity) {
        self.txType = txType
        switch activity {
        case let .lightning(ln):
            isLightning = true
            status = ln.status
            confirmed = nil
            isTransfer = false
        case let .onchain(onchain):
            isLightning = false
            status = nil
            confirmed = onchain.confirmed
            isTransfer = onchain.isTransfer
        }
    }

    var body: some View {
        if isTransfer {
            BodyMSBText(t("wallet__activity_transfer"), textColor: .textPrimary)
        } else if isLightning {
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

    private var amount: Int {
        switch item {
        case let .lightning(activity):
            if activity.txType == .sent {
                return Int(activity.value + (activity.fee ?? 0))
            } else {
                return Int(activity.value)
            }
        case let .onchain(activity):
            if activity.txType == .sent {
                return Int(activity.value + activity.fee)
            } else {
                return Int(activity.value)
            }
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ActivityIcon(activity: item, size: 40)

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
                case let .onchain(activity):
                    if activity.isTransfer {
                        switch activity.txType {
                        case .sent:
                            let captionText = if activity.confirmed {
                                "wallet__activity_transfer_spending_done"
                            } else {
                                t(
                                    "wallet__activity_transfer_spending_pending",
                                    variables: [
                                        "duration": formattedTime,
                                    ]
                                )
                            }

                            CaptionBText(captionText)
                        case .received:
                            let captionText = if activity.confirmed {
                                "wallet__activity_transfer_savings_done"
                            } else {
                                t(
                                    "wallet__activity_transfer_savings_pending",
                                    variables: [
                                        "duration": formattedTime,
                                    ]
                                )
                            }

                            CaptionBText(captionText)
                        }
                    } else {
                        CaptionBText(formattedTime)
                    }
                }
            }

            Spacer()

            MoneyCell(sats: amount, prefix: amountPrefix)
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(16)
    }
}
