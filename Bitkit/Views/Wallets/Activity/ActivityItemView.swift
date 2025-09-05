import BitkitCore
import LDKNode
import SwiftUI

struct ActivityItemView: View {
    let item: Activity
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @StateObject private var viewModel: ActivityItemViewModel

    init(item: Activity) {
        self.item = item
        _viewModel = StateObject(wrappedValue: ActivityItemViewModel(item: item))
    }

    private var isSent: Bool {
        switch viewModel.activity {
        case let .lightning(activity):
            return activity.txType == .sent
        case let .onchain(activity):
            return activity.txType == .sent
        }
    }

    private var isLightning: Bool {
        switch viewModel.activity {
        case .lightning:
            return true
        case .onchain:
            return false
        }
    }

    private var isTransfer: Bool {
        switch viewModel.activity {
        case .lightning:
            return false
        case let .onchain(activity):
            return activity.isTransfer
        }
    }

    private var amountPrefix: String {
        isSent ? "-" : "+"
    }

    private var activity: (timestamp: UInt64, fee: UInt64?, value: UInt64, txType: PaymentType) {
        switch viewModel.activity {
        case let .lightning(activity):
            return (activity.timestamp, activity.fee, activity.value, activity.txType)
        case let .onchain(activity):
            return (activity.timestamp, activity.fee, activity.value, activity.txType)
        }
    }

    private var amount: Int {
        if activity.txType == .sent {
            return Int(activity.value + (activity.fee ?? 0))
        } else {
            return Int(activity.value)
        }
    }

    private var accentColor: Color {
        isLightning ? .purpleAccent : .brandAccent
    }

    private var navigationTitle: String {
        if isTransfer {
            return isSent
                ? t("wallet__activity_transfer_spending_done")
                : t("wallet__activity_transfer_savings_done")
        }

        return isSent
            ? t("wallet__activity_bitcoin_sent")
            : t("wallet__activity_bitcoin_received")
    }

    private var formattedDateTime: (date: String, time: String) {
        return DateFormatterHelpers.formatActivityDetail(activity.timestamp)
    }

    private var shouldDisableBoostButton: Bool {
        switch viewModel.activity {
        case .lightning:
            // Lightning transactions can never be boosted
            return true
        case let .onchain(activity):
            // Disable boost for onchain if transaction is confirmed or already boosted
            return activity.confirmed == true || activity.isBoosted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationBar(title: navigationTitle)

            HStack(alignment: .bottom) {
                MoneyStack(sats: amount, prefix: amountPrefix, showSymbol: false)
                Spacer()
                ActivityIcon(activity: viewModel.activity, size: 48)
            }
            .padding(.bottom, 16)

            statusSection
            timestampSection
            feeSection
            tagsSection
            note
            buttons

            Spacer()
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onChange(of: sheets.addTagSheetItem) { item in
            if item == nil {
                // Add tag sheet was closed, reload tags in case they were modified
                Task {
                    await viewModel.loadTags()
                }
            }
        }
        .onChange(of: sheets.boostSheetItem) { item in
            if item == nil {
                // Boost sheet was closed, reload activity in case it was boosted
                Task {
                    await viewModel.refreshActivity()
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionText(t("wallet__activity_status"))
                .textCase(.uppercase)
                .padding(.bottom, 8)

            HStack(spacing: 4) {
                switch viewModel.activity {
                case let .lightning(activity):
                    switch activity.status {
                    case .pending:
                        Image("hourglass-simple")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_pending"), textColor: .purpleAccent)
                    case .succeeded:
                        Image("bolt")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_successful"), textColor: .purpleAccent)
                    case .failed:
                        Image("x-circle")
                            .foregroundColor(.purpleAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_failed"), textColor: .purpleAccent)
                    }
                case let .onchain(activity):
                    if activity.confirmed == true {
                        Image("check-circle")
                            .foregroundColor(.greenAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_confirmed"), textColor: .greenAccent)
                    } else if activity.isBoosted {
                        Image("hourglass-simple")
                            .foregroundColor(.yellowAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(
                            t("wallet__activity_confirms_in_boosted",
                              variables: ["feeRateDescription": t("fee__fast__shortDescription")]),
                            textColor: .yellowAccent
                        )
                    } else {
                        Image("hourglass-simple")
                            .foregroundColor(.brandAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_confirming"), textColor: .brandAccent)
                    }
                }
            }
            .padding(.bottom, 16)

            Divider()
        }
    }

    @ViewBuilder
    private var timestampSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(t("wallet__activity_date"))
                    .textCase(.uppercase)
                    .padding(.bottom, 8)

                HStack(spacing: 4) {
                    Image("calendar")
                        .foregroundColor(accentColor)
                        .frame(width: 16, height: 16)
                    BodySSBText(formattedDateTime.date)
                }
                .padding(.bottom, 16)

                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                CaptionText(t("wallet__activity_time"))
                    .textCase(.uppercase)
                    .padding(.bottom, 8)

                HStack(spacing: 4) {
                    Image("clock")
                        .foregroundColor(accentColor)
                        .frame(width: 16, height: 16)
                    BodySSBText(formattedDateTime.time)
                }
                .padding(.bottom, 16)

                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var feeSection: some View {
        if isSent {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionText(t("wallet__activity_payment"))
                        .textCase(.uppercase)
                        .padding(.bottom, 8)

                    HStack(spacing: 4) {
                        Image("user")
                            .foregroundColor(accentColor)
                            .frame(width: 16, height: 16)
                        MoneyText(sats: Int(activity.value), size: .bodySSB)
                    }
                    .padding(.bottom, 16)

                    Divider()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let fee = activity.fee {
                    VStack(alignment: .leading, spacing: 0) {
                        CaptionText(t("wallet__activity_fee"))
                            .textCase(.uppercase)
                            .padding(.bottom, 8)

                        HStack(spacing: 4) {
                            Image("timer")
                                .foregroundColor(accentColor)
                                .frame(width: 16, height: 16)
                            MoneyText(sats: Int(fee), size: .bodySSB)
                        }
                        .padding(.bottom, 16)

                        Divider()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        if !viewModel.tags.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(t("wallet__tags"))
                    .textCase(.uppercase)
                    .padding(.bottom, 8)

                WrappingHStack(spacing: 8) {
                    ForEach(viewModel.tags, id: \.self) { tag in
                        Tag(
                            tag,
                            onDelete: {
                                Task {
                                    await viewModel.removeTag(tag)
                                }
                            }
                        )
                    }
                }
                .padding(.bottom, 16)

                Divider()
            }
        }
    }

    @ViewBuilder
    private var note: some View {
        if case let .lightning(activity) = viewModel.activity {
            if !activity.message.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionText(t("wallet__activity_invoice_note"))
                        .textCase(.uppercase)
                        .padding(.bottom, 8)

                    VStack(alignment: .leading, spacing: 0) {
                        ZigzagDivider()

                        TitleText(activity.message, textColor: .primary)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white10)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        // TODO: add button actions
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                CustomButton(
                    title: t("wallet__activity_assign"), size: .small,
                    icon: Image("user-plus")
                        .foregroundColor(accentColor),
                    shouldExpand: true
                )

                CustomButton(
                    title: t("wallet__activity_tag"), size: .small,
                    icon: Image("tag")
                        .foregroundColor(accentColor),
                    shouldExpand: true
                ) {
                    let activityId: String = switch viewModel.activity {
                    case let .lightning(activity):
                        activity.id
                    case let .onchain(activity):
                        activity.id
                    }
                    sheets.showSheet(.addTag, data: AddTagConfig(activityId: activityId))
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 16) {
                CustomButton(
                    title: t("wallet__activity_boost"), size: .small,
                    icon: Image("timer-alt")
                        .foregroundColor(accentColor),
                    isDisabled: shouldDisableBoostButton,
                    shouldExpand: true
                ) {
                    // Only show boost sheet for onchain activities
                    if case let .onchain(onchainActivity) = viewModel.activity {
                        sheets.showSheet(.boost, data: BoostConfig(onchainActivity: onchainActivity))
                    }
                }

                CustomButton(
                    title: t("wallet__activity_explore"), size: .small,
                    icon: Image("branch")
                        .foregroundColor(accentColor),
                    shouldExpand: true
                ) {
                    navigation.navigate(.activityExplorer(viewModel.activity))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ZigzagDivider: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width + 48
                let height: CGFloat = 12
                let zigzagWidth: CGFloat = 24

                path.move(to: CGPoint(x: 0, y: height))

                var x: CGFloat = 0
                var toggle = false

                while x < width {
                    let nextX = min(x + zigzagWidth / 2, width)
                    path.addLine(to: CGPoint(x: nextX, y: toggle ? 0 : height))

                    toggle.toggle()
                    x = nextX
                }
            }
            .fill(Color.white10)
            .offset(x: -24, y: 0)
            .clipShape(Rectangle())
        }
        .frame(height: 12)
    }
}

struct ActivityItemView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Lightning Activity Preview
            ActivityItemView(
                item: .lightning(
                    LightningActivity(
                        id: "test-lightning-1",
                        txType: .sent,
                        status: .succeeded,
                        value: 50000,
                        fee: 1,
                        invoice:
                        "lnbcrt30u1p5ppdlupp5rs2w7htserff3zcwaz3ds205y8zzj4ax82qx6f4zj0f0lxzs7nasdqqcqzzsxqy9gcqsp59h735hvajjauzewf5dsemldwgra9mrfff3eha0mwqx2n7tp4wlmq9p4gqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpqysgqymzf4jnknunl6kxx2977xdy3g53m4wz9y8cds40v6ex89tct8tv8gzw40ddem70gfyr9nlfgadtzr6rk5cxuxknjx2j4ef998q8ga3sqhqlcux",
                        message: "Splitting the lunch bill. Thanks for suggesting that amazing restaurant!",
                        timestamp: UInt64(Date().timeIntervalSince1970),
                        preimage: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Lightning Payment")

            // Onchain Activity Preview
            ActivityItemView(
                item: .onchain(
                    OnchainActivity(
                        id: "test-onchain-1",
                        txType: .received,
                        txId: "abc123",
                        value: 100_000,
                        fee: 500,
                        feeRate: 8,
                        address: "bc1...",
                        confirmed: true,
                        timestamp: UInt64(Date().timeIntervalSince1970),
                        isBoosted: false,
                        isTransfer: false,
                        doesExist: true,
                        confirmTimestamp: nil,
                        channelId: nil,
                        transferTxId: nil,
                        createdAt: nil,
                        updatedAt: nil
                    )
                )
            )
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Onchain Payment")
        }
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
    }
}
