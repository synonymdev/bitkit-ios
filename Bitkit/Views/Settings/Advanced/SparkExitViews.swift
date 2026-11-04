import BreezSdkSpark
import SwiftUI

/// When to use an emergency exit, what it costs and how long it takes.
struct SparkExitIntroView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spark_exit__intro_title"), accentColor: .yellowAccent)

            BodyMText(t("lightning__spark_exit__intro_text"), accentFont: Fonts.bold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Spacer()

            Image("exclamation-mark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 256, maxHeight: 256)
                .frame(maxWidth: .infinity)

            Spacer()

            HStack(spacing: 16) {
                CustomButton(title: t("common__cancel"), variant: .secondary) {
                    navigation.navigateBack()
                }

                CustomButton(title: t("common__continue")) {
                    navigation.navigate(.sparkExitQuote)
                }
                .accessibilityIdentifier("SparkExitIntroContinue")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

/// What the exit takes on-chain, what it costs, and what stays behind.
struct SparkExitQuoteView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    private let exit = SparkExitManager.shared

    private var blockedReason: String? {
        guard let quote = exit.quote else { return exit.quoteError }
        if quote.prepared.leaves.isEmpty {
            return t("lightning__spark_exit__nothing")
        }
        if !quote.isWorthExiting {
            return t("lightning__spark_exit__uneconomic")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spark_exit__quote_title"), accentColor: .yellowAccent)
                .padding(.bottom, 32)

            if let quote = exit.quote {
                SparkExitQuoteRows(quote: quote)

                if let unexitableSats = SparkExitMath.unexitableSats(sparkBalanceSats: SparkManager.shared.balanceSats, quote: quote) {
                    CaptionMText(t("lightning__spark_exit__quote_outside", variables: ["amount": currency.primaryAmountText(sats: unexitableSats)]))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                        .accessibilityIdentifier("SparkExitQuoteOutside")
                }
            } else if exit.isQuoting {
                BodyMText(t(SparkManager.shared.isSettlingForExit ? "lightning__spark_exit__quote_settling" : "lightning__spark_exit__quote_loading"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let blockedReason {
                BodyMText(blockedReason, textColor: .redAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .accessibilityIdentifier("SparkExitQuoteBlocked")
            }

            Spacer()

            CustomButton(title: t("common__continue"), isLoading: exit.isQuoting) {
                guard let quote = exit.quote else { return }
                navigation.navigate(quote.fundingSats > 0 ? .sparkExitFunding : .sparkExitConfirm)
            }
            .disabled(exit.quote == nil || blockedReason != nil)
            .accessibilityIdentifier("SparkExitQuoteContinue")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await exit.loadQuote()
        }
    }
}

struct SparkExitQuoteRows: View {
    let quote: SparkExitQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkExitAmountRow(label: t("lightning__spark_exit__amount"), sats: quote.exitSats)
            SparkExitAmountRow(label: t("lightning__spark_exit__fees"), sats: quote.networkFeeSats)
            SparkExitAmountRow(label: t("lightning__spark_exit__receive"), sats: quote.receiveSats)
            if quote.fundingSats > 0 {
                SparkExitAmountRow(label: t("lightning__spark_exit__funding"), sats: quote.fundingSats)
            }
            if quote.leftBehindSats > 0 {
                SparkExitAmountRow(label: t("lightning__spark_exit__left_behind"), sats: quote.leftBehindSats)
            }
        }
    }
}

struct SparkExitAmountRow: View {
    let label: String
    let sats: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                CaptionBText(label, textColor: .textPrimary)
                Spacer()
                MoneyText(sats: Int(sats), size: .captionB, symbol: true)
            }
            .frame(height: 50)
            CustomDivider()
        }
    }
}

/// Pays the CPFP fee funding from savings, or shows the funding address to pay from another wallet.
struct SparkExitFundingView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var savingsFeeSats: UInt64?
    /// Savings can't pay the funding, usually because it doesn't hold enough.
    @State private var hasSavingsFeeFailed = false
    @State private var showsAddress = false

    private let exit = SparkExitManager.shared

    private var fundingSats: UInt64 {
        exit.quote?.fundingSats ?? 0
    }

    private var canFundFromSavings: Bool {
        guard let savingsFeeSats else { return false }
        return SparkExitMath.canFundFromSavings(
            spendableSats: UInt64(max(0, wallet.spendableOnchainBalanceSats)),
            fundingSats: fundingSats,
            paymentFeeSats: savingsFeeSats
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spark_exit__funding_title"), accentColor: .yellowAccent)

            BodyMText(
                t("lightning__spark_exit__funding_text", variables: ["amount": currency.primaryAmountText(sats: fundingSats)]),
                accentFont: Fonts.bold
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)

            if showsAddress, let address = exit.fundingAddress {
                SparkExitFundingAddress(address: address, requiredSats: fundingSats)
                    .padding(.top, 24)
            }

            Spacer()

            if showsAddress {
                CustomButton(title: t("common__continue")) {
                    exit.fundFromSavings = false
                    navigation.navigate(.sparkExitConfirm)
                }
                .disabled(exit.fundingSeenSats < fundingSats)
                .accessibilityIdentifier("SparkExitFundingContinue")
            } else {
                if hasSavingsFeeFailed || (savingsFeeSats != nil && !canFundFromSavings) {
                    CaptionMText(t("lightning__spark_exit__fund_insufficient"))
                        .padding(.bottom, 16)
                }

                CustomButton(title: t("lightning__spark_exit__fund_savings"), isLoading: savingsFeeSats == nil && !hasSavingsFeeFailed) {
                    exit.fundFromSavings = true
                    navigation.navigate(.sparkExitConfirm)
                }
                .disabled(!canFundFromSavings)
                .accessibilityIdentifier("SparkExitFundSavings")

                CustomButton(title: t("lightning__spark_exit__fund_external"), variant: .secondary) {
                    showsAddress = true
                }
                .padding(.top, 16)
                .accessibilityIdentifier("SparkExitFundExternal")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await estimateSavingsFee()
        }
        .task(id: showsAddress) {
            guard showsAddress else { return }
            await exit.watchFundingAddress()
        }
    }

    private func estimateSavingsFee() async {
        guard let address = exit.fundingAddress, fundingSats > 0,
              let feeRates = await feeEstimatesManager.getEstimates(refresh: true)
        else { return }
        let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
        do {
            let fee = try await wallet.calculateTotalFee(address: address, amountSats: fundingSats, satsPerVByte: rate)
            exit.savingsFeeRate = rate
            exit.savingsFeeSats = fee
            savingsFeeSats = fee
        } catch {
            Logger.warn("Failed to price the Spark exit funding from savings: \(error)", context: "SparkExitFundingView")
            hasSavingsFeeFailed = true
        }
    }
}

struct SparkExitFundingAddress: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    let address: String
    let requiredSats: UInt64
    /// Off where the caller shows what was seen itself.
    var showsSeen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            QR(content: address)
                .frame(maxWidth: 200)
                .frame(maxWidth: .infinity)

            CaptionMText(t("lightning__spark_exit__fund_external_text", variables: ["amount": currency.primaryAmountText(sats: requiredSats)]))

            Button {
                UIPasteboard.general.string = address
                Haptics.play(.copiedToClipboard)
                app.toast(type: .success, title: t("common__copied"), description: address)
            } label: {
                BodySText(address, textColor: .textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .contentShape(.rect)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityIdentifier("SparkExitFundingAddress")

            if showsSeen, SparkExitManager.shared.fundingSeenSats >= requiredSats, requiredSats > 0 {
                CaptionMText(t("lightning__spark_exit__fund_seen"), textColor: .greenAccent)
            }
        }
    }
}

/// A fee funding payment on its way: no QR and no amount to send, only what is awaited and its transaction.
struct SparkExitWaitingPayment: View {
    let text: String
    let txid: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(text, textColor: .greenAccent)
            CaptionMText(t("lightning__spark_exit__funding_txid", variables: ["txid": txid]))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SparkExitFundingWaiting")
    }
}

/// Where the ended exit's leftover fee funding is: on its way to savings, sent, or too small to send.
struct SparkExitLeftoverStatus: View {
    @EnvironmentObject var currency: CurrencyViewModel

    let record: SparkExitRecord
    let address: String

    private var leftoverSats: UInt64 {
        record.leftover.reduce(0) { $0 + $1.valueSats }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sweep = record.leftoverSweep, sweep.rejection == nil {
                if let txid = sweep.txid {
                    let key = sweep.isAccepted ? "lightning__spark_exit__leftover_swept" : "lightning__spark_exit__leftover_sending"
                    CaptionMText(t(key, variables: ["amount": currency.primaryAmountText(sats: sweep.valueSats)]))
                    if sweep.isAccepted {
                        CaptionMText(t("lightning__spark_exit__leftover_txid", variables: ["txid": txid]))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                } else {
                    CaptionMText(t(
                        "lightning__spark_exit__leftover_dust",
                        variables: ["amount": currency.primaryAmountText(sats: leftoverSats), "address": address]
                    ))
                }
            } else {
                ForEach(Array(record.leftover.enumerated()), id: \.offset) { _, leftover in
                    CaptionMText(t(
                        "lightning__spark_exit__leftover",
                        variables: ["amount": currency.primaryAmountText(sats: leftover.valueSats), "address": address]
                    ))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SparkExitLeftover")
    }
}

/// The last look before the exit starts: what arrives and for how long the funds are out of reach.
struct SparkExitConfirmView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    private let exit = SparkExitManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spark_exit__confirm_title"), accentColor: .yellowAccent)

            BodyMText(t("lightning__spark_exit__confirm_text"), accentFont: Fonts.bold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.bottom, 32)

            if let quote = exit.quote {
                SparkExitQuoteRows(quote: quote)
            }

            SparkExitBackgroundNotes()
                .padding(.top, 16)

            Spacer()

            SwipeButton(title: t("lightning__spark_exit__swipe"), accentColor: .yellowAccent) {
                do {
                    try await exit.start()
                    navigation.navigate(.sparkExitProgress)
                } catch {
                    app.toast(error)
                    // The exit started but paying its fee funding failed: the progress screen shows where to fund it.
                    if exit.isExiting {
                        navigation.navigate(.sparkExitProgress)
                        return
                    }
                    throw error
                }
            }
            .accessibilityIdentifier("SparkExitSwipe")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            // Asked before the swipe: the reminders are how Bitkit reaches the user when a step needs the app.
            PushNotificationManager.shared.requestPermissionIfUndecided()
        }
    }
}

/// The running exit's steps and countdown, and its result once it ends.
struct SparkExitProgressView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    private let exit = SparkExitManager.shared

    private var record: SparkExitRecord? {
        exit.record
    }

    private var fundingState: SparkExitFundingState? {
        guard let record, record.fundingShortfallSats != nil else { return nil }
        return exit.fundingState ?? SparkExitMath.fundingState(record, utxos: nil)
    }

    private var lostText: String? {
        guard let record, record.lostSats > 0 else { return nil }
        return t("lightning__spark_exit__lost_leaves", variables: ["amount": currency.primaryAmountText(sats: record.lostSats)])
    }

    private var title: String {
        switch record?.phase {
        case .done: t("lightning__spark_exit__done_title")
        case .failed: t("lightning__spark_exit__failed_title")
        case .needsFunding: t("lightning__spark_exit__needs_funding_title")
        default: t("lightning__spark_exit__progress_title")
        }
    }

    private var text: String {
        switch record?.phase {
        case .done:
            [
                t("lightning__spark_exit__done_text"),
                (record?.skippedLeafCount ?? 0) > 0
                    ? t("lightning__spark_exit__partial_text", variables: ["count": "\(record?.skippedLeafCount ?? 0)"]) : nil,
                (record?.failedLeafCount ?? 0) > 0
                    ? t("lightning__spark_exit__failed_leaves", variables: ["count": "\(record?.failedLeafCount ?? 0)"]) : nil,
            ].compactMap { $0 }.joined(separator: " ")
        case .failed: lostText ?? t("lightning__spark_exit__failed_text")
        case .needsFunding:
            t(
                "lightning__spark_exit__needs_funding_text",
                variables: ["amount": currency.primaryAmountText(sats: askSats ?? record?.fundingShortfallSats ?? 0)]
            )
        default: t("lightning__spark_exit__progress_text")
        }
    }

    private var isFailed: Bool {
        if case .failed = record?.phase {
            return true
        }
        return false
    }

    private var askSats: UInt64? {
        if case let .ask(sats) = fundingState {
            return sats
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            DisplayText(title, accentColor: .yellowAccent)
                .padding(.bottom, 16)

            BodyMText(text, accentFont: Fonts.bold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let record {
                        SparkExitSteps(record: record, tipHeight: exit.tipHeight)

                        if let address = record.funding.first?.address {
                            switch fundingState {
                            case let .ask(sats):
                                SparkExitFundingAddress(address: address, requiredSats: sats, showsSeen: false)
                                    .padding(.top, 24)
                            case let .paid(txid):
                                SparkExitWaitingPayment(text: t("lightning__spark_exit__fund_paid"), txid: txid)
                                    .padding(.top, 24)
                            case let .seen(txid):
                                SparkExitWaitingPayment(text: t("lightning__spark_exit__fund_pending"), txid: txid)
                                    .padding(.top, 24)
                            case nil:
                                EmptyView()
                            }
                        }

                        // An exit that failed says it in its text.
                        if let lostText, !isFailed {
                            CaptionMText(lostText, textColor: .redAccent)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitLostLeaves")
                        }

                        if let rejection = record.surfacedRejection {
                            CaptionMText(t("lightning__spark_exit__errors", variables: ["error": rejection]), textColor: .redAccent)
                                .padding(.top, 16)
                        }

                        if let outsideSats = SparkExitMath.outsideExitSats(sparkBalanceSats: SparkManager.shared.balanceSats, record: record) {
                            CaptionMText(t(
                                "lightning__spark_exit__outside_exit",
                                variables: ["amount": currency.primaryAmountText(sats: outsideSats)]
                            ))
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitOutsideExit")
                        }

                        if record.isActive {
                            SparkExitBackgroundNotes()
                                .padding(.top, 16)
                        }

                        if !record.isActive, !record.leftover.isEmpty, let address = record.funding.first?.address {
                            SparkExitLeftoverStatus(record: record, address: address)
                                .padding(.top, 16)
                        }
                    }
                }
            }

            if exit.canCancel {
                CustomButton(title: t("lightning__spark_exit__cancel"), variant: .secondary) {
                    Task {
                        await exit.cancel()
                        navigation.reset()
                    }
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("SparkExitCancel")
            }

            CustomButton(title: t("common__ok")) {
                navigation.reset()
            }
            .accessibilityIdentifier("SparkExitProgressOk")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .refreshable {
            await SparkManager.shared.refreshState()
            await exit.tick()
        }
        .task {
            await SparkManager.shared.refreshState()
            await exit.tick()
        }
    }
}

/// What keeps the exit from moving or from reaching the user while Bitkit is closed: Background App Refresh off,
/// Low Power Mode, or notifications denied. Each note shows only while its setting is in the way.
struct SparkExitBackgroundNotes: View {
    @ObservedObject private var notifications = PushNotificationManager.shared
    @State private var refreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var notes: [String] {
        [
            refreshStatus == .available ? nil : t("lightning__spark_exit__bg_refresh_off"),
            isLowPower ? t("lightning__spark_exit__low_power") : nil,
            notifications.authorizationStatus == .denied ? t("lightning__spark_exit__notifications_off") : nil,
        ].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notes, id: \.self) { note in
                CaptionMText(note, textColor: .yellowAccent)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SparkExitBackgroundNotes")
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in refresh() }
    }

    private func refresh() {
        DispatchQueue.main.async {
            refreshStatus = UIApplication.shared.backgroundRefreshStatus
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        notifications.updateNotificationPermission()
    }
}

struct SparkExitSteps: View {
    let record: SparkExitRecord
    let tipHeight: UInt32?

    private var transactions: [RecoveryTransaction] {
        record.recovery?.response.transactions ?? []
    }

    private var isFunded: Bool {
        if case .awaitingFunding = record.phase {
            return false
        }
        return true
    }

    private var remainingDuration: String? {
        guard let target = record.claimableAtHeight, let tipHeight else { return nil }
        let blocks = BlockTimeHelpers.blocksRemaining(until: target, currentHeight: tipHeight)
        guard blocks > 0 else { return nil }
        return BlockTimeHelpers.getDurationForBlocks(blocks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(t("lightning__spark_exit__step_funding"), isDone: isFunded)
            step(
                t("lightning__spark_exit__step_publish"),
                detail: record.recovery.map { "\(SparkExitMath.confirmedCount($0.response))/\(transactions.count)" },
                isDone: record.phase == .done
            )
            step(
                t("lightning__spark_exit__step_timelock"),
                detail: remainingDuration.map { t("lightning__spark_exit__ready_in", variables: ["duration": $0]) },
                isDone: record.phase == .done || SparkExitMath.areTimelocksMatured(transactions)
            )
            step(t("lightning__spark_exit__step_sweep"), isDone: record.phase == .done)
        }
    }

    private func step(_ title: String, detail: String? = nil, isDone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(isDone ? "check-mark" : "hourglass")
                    .resizable()
                    .foregroundColor(isDone ? .greenAccent : .textSecondary)
                    .frame(width: 20, height: 20)
                CaptionBText(title, textColor: .textPrimary)
                Spacer()
                if let detail {
                    CaptionBText(detail)
                }
            }
            .frame(height: 50)
            CustomDivider()
        }
    }
}
