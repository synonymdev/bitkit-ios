import BitkitCore
import SwiftUI

struct ActivityRow: View {
    let item: Activity
    let feeEstimates: FeeRates?
    let contact: PubkyContact?
    let titleOverride: String?
    let showContactAvatar: Bool

    init(item: Activity, feeEstimates: FeeRates?, contact: PubkyContact? = nil, titleOverride: String? = nil, showContactAvatar: Bool = true) {
        self.item = item
        self.feeEstimates = feeEstimates
        self.contact = contact
        self.titleOverride = titleOverride
        self.showContactAvatar = showContactAvatar
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

    private var rowContactAvatar: PubkyContact? {
        guard showContactAvatar, contactTitle != nil else {
            return nil
        }

        return contact
    }

    var body: some View {
        ActivityRowContainer {
            switch item {
            case let .lightning(activity):
                ActivityRowLightning(item: activity, contact: rowContactAvatar, titleOverride: rowTitleOverride)
            case let .onchain(activity):
                ActivityRowOnchain(item: activity, feeEstimates: feeEstimates, contact: rowContactAvatar, titleOverride: rowTitleOverride)
            }
        }
    }
}

struct ActivityRowContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().padding(16).background(Color.gray6).cornerRadius(16)
    }
}

struct ActivityRowContent<Icon: View, Amount: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var amount: () -> Amount

    var body: some View {
        HStack(spacing: 16) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                BodyMSBText(title).lineLimit(1)
                CaptionBText(subtitle).lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            amount()
        }
    }
}

enum WalletActivity: Hashable {
    case bitcoin(Activity)
    case usdt(UsdtTransfer)

    var timestamp: UInt64 {
        switch self {
        case let .bitcoin(.lightning(item)): item.timestamp
        case let .bitcoin(.onchain(item)): item.timestamp
        case let .usdt(item): item.timestamp
        }
    }

    var groupTitle: String {
        DateFormatterHelpers.getActivityGroupHeader(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func merged(_ bitcoin: [Activity], _ usdt: [UsdtTransfer]) -> [WalletActivity] {
        (bitcoin.map(Self.bitcoin) + usdt.map(Self.usdt)).sorted { $0.timestamp > $1.timestamp }
    }
}

struct WalletActivityRow: View {
    let item: WalletActivity
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = PaykitFeatureFlags.uiEnabledByDefault
    @EnvironmentObject private var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var settings: SettingsViewModel

    var body: some View {
        switch item {
        case let .bitcoin(activity):
            NavigationLink(value: Route.activityDetail(activity)) {
                ActivityRow(item: activity, feeEstimates: feeEstimatesManager.estimates,
                            contact: PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled ? activity.contact(in: contactsManager.contacts) : nil)
            }
        case let .usdt(transfer):
            NavigationLink(value: Route.usdtActivity(transferId: transfer.id)) {
                UsdtActivityRow(transfer: transfer, hideBalance: settings.hideBalance)
            }
        }
    }
}
