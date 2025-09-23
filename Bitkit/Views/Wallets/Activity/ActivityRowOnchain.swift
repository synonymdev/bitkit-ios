import BitkitCore
import SwiftUI

private struct ActivityStatus: View {
    let txType: PaymentType
    let confirmed: Bool
    let isTransfer: Bool

    var body: some View {
        if isTransfer {
            BodyMSBText(t("wallet__activity_transfer"))
        } else {
            if txType == .sent {
                BodyMSBText(t("wallet__activity_sent"))
            } else {
                BodyMSBText(t("wallet__activity_received"))
            }
        }
    }
}

struct ActivityRowOnchain: View {
    let item: OnchainActivity
    let feeEstimates: FeeRates?

    private var amountPrefix: String {
        return item.txType == .sent ? "-" : "+"
    }

    private var amount: Int {
        if item.txType == .sent {
            return Int(item.value + item.fee)
        } else {
            return Int(item.value)
        }
    }

    private var formattedTime: String {
        return DateFormatterHelpers.getActivityItemDate(item.timestamp)
    }

    private var description: String {
        if item.isTransfer {
            switch item.txType {
            case .sent:
                return item.confirmed ?
                    t("wallet__activity_transfer_spending_done") :
                    t("wallet__activity_transfer_spending_pending", variables: ["duration": "TODO"])
            case .received:
                return item.confirmed ?
                    t("wallet__activity_transfer_savings_done") :
                    t("wallet__activity_transfer_savings_pending", variables: ["duration": "TODO"])
            }
        } else {
            if item.confirmed {
                return formattedTime
            } else {
                let feeDescription = TransactionSpeed.getFeeDescription(feeRate: item.feeRate, feeEstimates: feeEstimates)
                return t("wallet__activity_confirms_in", variables: ["feeRateDescription": feeDescription])
            }
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ActivityIcon(activity: .onchain(item), size: 40)

            VStack(alignment: .leading, spacing: 2) {
                ActivityStatus(txType: item.txType, confirmed: item.confirmed, isTransfer: item.isTransfer)
                CaptionBText(description)
            }

            Spacer()

            MoneyCell(sats: amount, prefix: amountPrefix)
        }
    }
}
