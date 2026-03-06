import BitkitCore
import SwiftUI

struct ActivityRowOnchain: View {
    let item: OnchainActivity
    let feeEstimates: FeeRates?

    @State private var isCpfpChild: Bool = false

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

    private var feeDescription: String {
        TransactionSpeed.getFeeTierLocalized(feeRate: item.feeRate, feeEstimates: feeEstimates, variant: .shortDescription)
    }

    private var status: String {
        if item.isTransfer {
            return item.confirmed ? t("wallet__activity_transfer") : t("wallet__activity_transferring")
        }
        if isCpfpChild {
            return t("wallet__activity_boost_fee")
        }
        if item.isBoosted && !item.confirmed {
            return t("wallet__activity_boosting")
        }
        return item.txType == .sent ? t("wallet__activity_sent") : t("wallet__activity_received")
    }

    private var description: String {
        if !item.doesExist {
            return t("wallet__activity_removed")
        }

        if isCpfpChild {
            return t("wallet__activity_boost_fee_description")
        }

        if item.isTransfer {
            switch item.txType {
            case .sent:
                return item.confirmed ?
                    t("wallet__activity_transfer_spending_done") :
                    t("wallet__activity_transfer_spending_pending", variables: ["duration": feeDescription])
            case .received:
                return item.confirmed ?
                    t("wallet__activity_transfer_savings_done") :
                    t("wallet__activity_transfer_savings_pending", variables: ["duration": feeDescription])
            }
        } else {
            if item.confirmed {
                return DateFormatterHelpers.getActivityItemDate(item.timestamp)
            } else {
                return t("wallet__activity_confirms_in", variables: ["feeRateDescription": feeDescription])
            }
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ActivityIcon(activity: .onchain(item), size: 40, isCpfpChild: isCpfpChild, context: .row)

            VStack(alignment: .leading, spacing: 2) {
                BodyMSBText(status).lineLimit(1)
                CaptionBText(description).lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            MoneyCell(sats: amount, prefix: amountPrefix, enableHide: true)
        }
        .task {
            isCpfpChild = await CoreService.shared.activity.isCpfpChildTransaction(txId: item.txId)
        }
    }
}
