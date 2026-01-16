import BitkitCore
import SwiftUI

private struct ActivityStatus: View {
    let txType: PaymentType
    let confirmed: Bool
    let isTransfer: Bool
    let isCpfpChild: Bool

    var body: some View {
        if isTransfer {
            BodyMSBText(t("wallet__activity_transfer"))
        } else {
            if isCpfpChild {
                BodyMSBText(t("wallet__activity_boost_fee"))
            } else if txType == .sent {
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

    private var formattedTime: String {
        return DateFormatterHelpers.getActivityItemDate(item.timestamp)
    }

    private var feeDescription: String {
        TransactionSpeed.getFeeDescription(feeRate: item.feeRate, feeEstimates: feeEstimates)
    }

    private var durationWithoutSymbol: String {
        // Remove ± symbol since localization strings already include it
        feeDescription.replacingOccurrences(of: "±", with: "")
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
                    t("wallet__activity_transfer_spending_pending", variables: ["duration": durationWithoutSymbol])
            case .received:
                return item.confirmed ?
                    t("wallet__activity_transfer_savings_done") :
                    t("wallet__activity_transfer_savings_pending", variables: ["duration": durationWithoutSymbol])
            }
        } else {
            if item.confirmed {
                return formattedTime
            } else {
                return t("wallet__activity_confirms_in", variables: ["feeRateDescription": feeDescription])
            }
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ActivityIcon(activity: .onchain(item), size: 40, isCpfpChild: isCpfpChild)

            VStack(alignment: .leading, spacing: 2) {
                ActivityStatus(
                    txType: item.txType,
                    confirmed: item.confirmed,
                    isTransfer: item.isTransfer,
                    isCpfpChild: isCpfpChild
                )
                .lineLimit(1)
                CaptionBText(description)
                    .lineLimit(1)
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
