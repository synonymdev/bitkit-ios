import BitkitCore
import SwiftUI

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

    private var status: String {
        switch item.status {
        case .failed:
            return t("wallet__activity_failed")
        case .pending:
            return t("wallet__activity_pending")
        case .succeeded:
            return item.txType == .sent ? t("wallet__activity_sent") : t("wallet__activity_received")
        }
    }

    private var description: String {
        return item.message.isEmpty ? formattedTime : item.message
    }

    var body: some View {
        HStack(spacing: 16) {
            ActivityIcon(activity: .lightning(item), size: 40, context: .row)

            VStack(alignment: .leading, spacing: 2) {
                BodyMSBText(status).lineLimit(1)
                CaptionBText(description).lineLimit(1)
            }

            Spacer()

            MoneyCell(sats: amount, prefix: amountPrefix, enableHide: true)
        }
    }
}
