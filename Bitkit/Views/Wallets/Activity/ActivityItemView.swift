import BitkitCore
import LDKNode
import SwiftUI

struct ActivityItemView: View {
    let item: Activity
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false

    @EnvironmentObject var activityList: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var channelDetails: ChannelDetailsViewModel
    @StateObject private var viewModel: ActivityItemViewModel
    @State private var boostTxDoesExist: [String: Bool] = [:] // Maps boostTxId -> doesExist
    @State private var isCpfpChild: Bool = false

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

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

    private var isTransferFromSpending: Bool {
        isTransfer && !isSent
    }

    private var isTransferToSpending: Bool {
        isTransfer && isSent
    }

    private var accentColor: Color {
        if isTransferFromSpending {
            return .purpleAccent
        }
        return isLightning ? .purpleAccent : .brandAccent
    }

    private var duration: String {
        guard case let .onchain(activity) = item else { return "" }
        return TransactionSpeed.getFeeTierLocalized(
            feeRate: activity.feeRate,
            feeEstimates: feeEstimatesManager.estimates,
            variant: .shortDescription
        )
    }

    private var transferChannelId: String? {
        guard case let .onchain(activity) = viewModel.activity else { return nil }
        return activity.channelId
    }

    private var assignedContact: PubkyContact? {
        guard isPaykitUIActive else { return nil }
        return viewModel.activity.contact(in: contactsManager.contacts)
    }

    private var navigationTitle: String {
        if isTransfer {
            return isTransferToSpending
                ? t("wallet__activity_transfer_spending_done")
                : t("wallet__activity_transfer_savings_done")
        }

        if isCpfpChild {
            return t("wallet__activity_boost_fee")
        }

        if case let .lightning(activity) = viewModel.activity, activity.status == .pending {
            return t("wallet__activity_pending_nav_title")
        }

        return isSent
            ? t("wallet__activity_bitcoin_sent")
            : t("wallet__activity_bitcoin_received")
    }

    private var formattedDateTime: (date: String, time: String) {
        return DateFormatterHelpers.formatActivityDetail(activity.timestamp)
    }

    private var isHardwareActivity: Bool {
        viewModel.activity.isHardwareWallet
    }

    private var shouldDisableBoostButton: Bool {
        // Watch-only hardware wallets have no signing keys, so RBF is impossible.
        if isHardwareActivity {
            return true
        }
        switch viewModel.activity {
        case .lightning:
            return true
        case let .onchain(activity):
            if isCpfpChild {
                return true
            }
            if !activity.doesExist {
                return true
            }
            if activity.confirmed == true {
                return true
            }
            if activity.isBoosted && !activity.boostTxIds.isEmpty {
                if activity.txType == .sent {
                    return true
                } else {
                    return activity.boostTxIds.contains { boostTxDoesExist[$0] == true }
                }
            }

            return false
        }
    }

    private func loadBoostTxDoesExist() async {
        guard case let .onchain(activity) = viewModel.activity else { return }

        let doesExistMap = await CoreService.shared.activity.getBoostTxDoesExist(boostTxIds: activity.boostTxIds)
        await MainActor.run {
            boostTxDoesExist = doesExistMap
        }
    }

    private var boostButtonIdentifier: String {
        switch viewModel.activity {
        case let .onchain(activity):
            if activity.isBoosted {
                return "BoostedButton"
            }
            return shouldDisableBoostButton ? "BoostDisabled" : "BoostButton"
        case .lightning:
            return "BoostDisabled"
        }
    }

    private var statusAccessibilityIdentifier: String? {
        switch viewModel.activity {
        case let .onchain(activity):
            if !activity.doesExist {
                return "StatusRemoved"
            }
            if activity.confirmed == true {
                return "StatusConfirmed"
            }
            if activity.isBoosted {
                return "StatusBoosting"
            }
            return "StatusConfirming"
        case .lightning:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: navigationTitle)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    HStack(alignment: .bottom) {
                        MoneyStack(sats: amount, prefix: amountPrefix, showSymbol: false)
                        Spacer()
                        ActivityIcon(activity: viewModel.activity, size: 48, isCpfpChild: isCpfpChild)
                            .offset(y: 5) // Align arrow with bottom of money stack
                    }
                    .padding(.bottom, 16)

                    statusSection
                    timestampSection
                    feeSection
                    contactTagsSection
                    note
                    buttons

                    Spacer()
                }
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .onChange(of: sheets.addTagSheetItem) { _, item in
            if item == nil {
                // Add tag sheet was closed, reload tags in case they were modified
                Task {
                    await viewModel.loadTags()
                }
            }
        }
        .onChange(of: sheets.boostSheetItem) { _, item in
            if item == nil {
                // Boost sheet was closed, reload activity in case it was boosted
                Task {
                    await viewModel.refreshActivity()
                }
            }
        }
        .task {
            // Check if this is a CPFP child transaction
            if case let .onchain(activity) = viewModel.activity {
                isCpfpChild = await CoreService.shared.activity.isCpfpChildTransaction(txId: activity.txId)
            }

            // Load boostTxIds doesExist status to determine RBF vs CPFP
            if case let .onchain(activity) = viewModel.activity,
               !activity.boostTxIds.isEmpty
            {
                await loadBoostTxDoesExist()
            }
            // Load channel if this is a transfer
            if isTransfer, let channelId = transferChannelId {
                await channelDetails.findChannel(channelId: channelId, wallet: wallet)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(t("wallet__activity_status"))
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
                            .resizable()
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
                    if !activity.doesExist {
                        Image("x-mark")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.redAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_removed"), textColor: .redAccent)
                    } else if activity.confirmed == true {
                        Image("check-circle")
                            .foregroundColor(.greenAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_confirmed"), textColor: .greenAccent)
                    } else if activity.isBoosted {
                        Image("timer-alt")
                            .foregroundColor(.yellowAccent)
                            .frame(width: 16, height: 16)
                        BodySSBText(t("wallet__activity_boosting"), textColor: .yellowAccent)
                    } else {
                        // Use accent color for transfers (purple for from spending, orange for from savings)
                        let statusColor = isTransfer ? accentColor : .brandAccent
                        let statusText = isTransfer ? t("wallet__activity_in_transfer", variables: ["duration": duration]) :
                            t("wallet__activity_confirming")

                        Image("hourglass-simple")
                            .foregroundColor(statusColor)
                            .frame(width: 16, height: 16)
                        BodySSBText(statusText, textColor: statusColor)
                    }
                }
            }
            .accessibilityIdentifierIfPresent(statusAccessibilityIdentifier)
            .padding(.bottom, 16)

            Divider()
        }
    }

    private var timestampSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("wallet__activity_date"))
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
                CaptionMText(t("wallet__activity_time"))
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
        if isSent || isTransfer {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(
                        isTransferToSpending ? t("wallet__activity_transfer_to_spending") :
                            isTransferFromSpending ? t("wallet__activity_transfer_to_savings") :
                            t("wallet__activity_payment")
                    )
                    .padding(.bottom, 8)

                    HStack(spacing: 4) {
                        Image(
                            isTransferToSpending ? "bolt-hollow" :
                                isTransferFromSpending ? "status-bitcoin" :
                                "user"
                        )
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(accentColor)
                        .frame(width: 16, height: 16)
                        MoneyText(sats: Int(activity.value), size: .bodySSB, testIdentifier: "MoneyText")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("ActivityAmount")
                    .padding(.bottom, 16)

                    Divider()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let feeAmount = viewModel.calculateFeeAmount(linkedOrder: channelDetails.linkedOrder) {
                    let feeLabel = isTransferFromSpending ? t("wallet__activity_fee_prepaid") : t("wallet__activity_fee")

                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(feeLabel)
                            .padding(.bottom, 8)

                        HStack(spacing: 4) {
                            Image("timer")
                                .foregroundColor(accentColor)
                                .frame(width: 16, height: 16)
                            MoneyText(sats: Int(feeAmount), size: .bodySSB, testIdentifier: "MoneyText")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("ActivityFee")
                        .padding(.bottom, 16)

                        Divider()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var contactTagsSection: some View {
        if assignedContact != nil, !viewModel.tags.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                contactCell
                    .frame(maxWidth: .infinity, alignment: .leading)

                tagsCell
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if assignedContact != nil {
            contactCell
        } else if !viewModel.tags.isEmpty {
            tagsCell
        }
    }

    @ViewBuilder
    private var contactCell: some View {
        if let assignedContact {
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("wallet__activity_contact"))
                    .padding(.bottom, 8)

                Button {
                    navigation.navigate(.contactDetail(publicKey: assignedContact.publicKey))
                } label: {
                    HStack(spacing: 8) {
                        PubkyContactAvatar(contact: assignedContact, size: 24)
                        BodySSBText(assignedContact.displayName)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.gray6)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)

                Divider()
            }
        }
    }

    @ViewBuilder
    private var tagsCell: some View {
        if !viewModel.tags.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("wallet__tags"))
                    .padding(.bottom, 8)

                TagsListView(
                    tags: viewModel.tags,
                    icon: .close,
                    onTagDelete: { tag in
                        Task {
                            await viewModel.removeTag(tag)
                        }
                    }
                )
                .padding(.bottom, 16)
                .accessibilityIdentifier("ActivityTags")

                Divider()
            }
        }
    }

    @ViewBuilder
    private var note: some View {
        if case let .lightning(activity) = viewModel.activity {
            if !activity.message.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("wallet__activity_invoice_note"))
                        .padding(.bottom, 8)

                    VStack(alignment: .leading, spacing: 0) {
                        ZigzagDivider()

                        TitleText(activity.message, textColor: .primary)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white10)
                            .accessibilityIdentifier("InvoiceNote")
                    }
                }
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 16) {
            // Contact and tag actions are hidden for watch-only hardware wallets.
            if !isHardwareActivity {
                HStack(spacing: 16) {
                    if isPaykitUIActive {
                        CustomButton(
                            title: assignedContact == nil ? t("wallet__activity_assign") : t("wallet__activity_detach"), size: .small,
                            icon: Image(assignedContact == nil ? "user-plus" : "user-minus")
                                .foregroundColor(accentColor),
                            shouldExpand: true
                        ) {
                            if assignedContact == nil {
                                navigation.navigate(.assignActivityContact(activityId: viewModel.activityId))
                            } else {
                                Task {
                                    await detachContact()
                                }
                            }
                        }
                        .accessibilityIdentifier(assignedContact == nil ? "ActivityAssignContact" : "ActivityDetachContact")
                    }

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
                    .accessibilityIdentifier("ActivityTag")
                }
                .frame(maxWidth: .infinity)
            }

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
                .accessibilityIdentifier(boostButtonIdentifier)

                exploreButton
            }
            .frame(maxWidth: .infinity)

            if isTransfer, let channelId = transferChannelId {
                CustomButton(
                    title: t("lightning__connection"), size: .small,
                    icon: Image("bolt-hollow")
                        .foregroundColor(accentColor),
                    shouldExpand: true
                ) {
                    navigation.navigate(.connectionDetail(channelId: channelId))
                }
                .accessibilityIdentifier("ChannelButton")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var exploreButton: some View {
        CustomButton(
            title: t("wallet__activity_explore"), size: .small,
            icon: Image("branch")
                .foregroundColor(accentColor),
            shouldExpand: true
        ) {
            navigation.navigate(.activityExplorer(viewModel.activity))
        }
        .accessibilityIdentifier("ActivityTxDetails")
    }

    private func detachContact() async {
        do {
            try await activityList.setContact(nil, forPaymentId: viewModel.activityId)
            await viewModel.refreshActivity()
        } catch {
            Logger.error("Failed to detach contact from activity \(viewModel.activityId): \(error)", context: "ActivityItemView")
            app.toast(type: .error, title: t("contacts__error_saving"), description: error.localizedDescription)
        }
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
                        walletId: WalletScope.default,
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
                        contact: nil,
                        createdAt: nil,
                        updatedAt: nil,
                        seenAt: nil
                    )
                )
            )
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Lightning Payment")

            // Onchain Activity Preview
            ActivityItemView(
                item: .onchain(
                    OnchainActivity(
                        walletId: WalletScope.default,
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
                        boostTxIds: [],
                        isTransfer: false,
                        doesExist: true,
                        confirmTimestamp: nil,
                        channelId: nil,
                        transferTxId: nil,
                        contact: nil,
                        createdAt: nil,
                        updatedAt: nil,
                        seenAt: nil
                    )
                )
            )
            .environmentObject(CurrencyViewModel())
            .previewDisplayName("Onchain Payment")
        }
        .environmentObject(AppViewModel())
        .environmentObject(FeeEstimatesManager())
        .preferredColorScheme(.dark)
    }
}
