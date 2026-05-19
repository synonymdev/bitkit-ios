import BitkitCore
import SwiftUI

struct ActivityRow: View {
    let item: Activity
    let feeEstimates: FeeRates?
    let contact: PubkyContact?
    let titleOverride: String?

    init(item: Activity, feeEstimates: FeeRates?, contact: PubkyContact? = nil, titleOverride: String? = nil) {
        self.item = item
        self.feeEstimates = feeEstimates
        self.contact = contact
        self.titleOverride = titleOverride
    }

    private var rowTitleOverride: String? {
        if let titleOverride {
            return titleOverride
        }

        return contactTitle
    }

    private var contactTitle: String? {
        guard let contact else { return nil }

        let txType: PaymentType
        switch item {
        case let .lightning(lightning):
            guard lightning.status == .succeeded else {
                return nil
            }
            txType = lightning.txType

        case let .onchain(onchain):
            guard onchain.doesExist,
                  !onchain.isTransfer,
                  !(onchain.isBoosted && !onchain.confirmed)
            else {
                return nil
            }
            txType = onchain.txType
        }

        switch txType {
        case .sent:
            return t("contacts__activity_sent_to", variables: ["name": contact.displayName])
        case .received:
            return t("contacts__activity_received_from", variables: ["name": contact.displayName])
        }
    }

    var body: some View {
        Group {
            switch item {
            case let .lightning(activity):
                ActivityRowLightning(item: activity, titleOverride: rowTitleOverride)
            case let .onchain(activity):
                ActivityRowOnchain(item: activity, feeEstimates: feeEstimates, titleOverride: rowTitleOverride)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(16)
    }
}
