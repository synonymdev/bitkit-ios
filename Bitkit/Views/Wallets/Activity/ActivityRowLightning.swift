import BitkitCore
import SwiftUI

private struct ActivityStatus: View {
    let txType: PaymentType
    let status: PaymentState

    var body: some View {
        switch status {
        case .failed:
            BodyMSBText(t("wallet__activity_failed"))
        case .pending:
            BodyMSBText(t("wallet__activity_pending"))
        case .succeeded:
            if txType == .sent {
                BodyMSBText(t("wallet__activity_sent"))
            } else {
                BodyMSBText(t("wallet__activity_received"))
            }
        }
    }
}

struct ActivityRowLightning: View {
    let item: LightningActivity

    private var amountPrefix: String {
        return item.txType == .sent ? "-" : "+"
    }

    private var amount: Int {
        if item.txType == .sent {
            return Int(item.value + (item.fee ?? 0))
        } else {
            return Int(item.value)
        }
    }

    private var formattedTime: String {
        return DateFormatterHelpers.getActivityItemDate(item.timestamp)
    }

    var body: some View {
        HStack(spacing: 16) {
            ActivityIcon(activity: .lightning(item), size: 40)

            VStack(alignment: .leading, spacing: 2) {
                ActivityStatus(txType: item.txType, status: item.status)
                CaptionBText(item.message.isEmpty ? formattedTime : item.message)
                    .lineLimit(1)
            }

            Spacer()

            MoneyCell(sats: amount, prefix: amountPrefix)
        }
    }
}
