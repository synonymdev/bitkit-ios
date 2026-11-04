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
            } else if exit.isQuoting {
                BodyMText(t("lightning__spark_exit__quote_loading"))
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

            if SparkExitManager.shared.fundingSeenSats >= requiredSats, requiredSats > 0 {
                CaptionMText(t("lightning__spark_exit__fund_seen"), textColor: .greenAccent)
            }
        }
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
        case .failed: t("lightning__spark_exit__failed_text")
        case .needsFunding:
            t("lightning__spark_exit__needs_funding_text", variables: ["amount": currency.primaryAmountText(sats: record?.fundingShortfallSats ?? 0)])
        default: t("lightning__spark_exit__progress_text")
        }
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

                        if let requiredSats = record.fundingShortfallSats, let address = record.funding.first?.address {
                            SparkExitFundingAddress(address: address, requiredSats: requiredSats)
                                .padding(.top, 24)
                        }

                        if let rejection = record.surfacedRejection {
                            CaptionMText(t("lightning__spark_exit__errors", variables: ["error": rejection]), textColor: .redAccent)
                                .padding(.top, 16)
                        }

                        if record.phase == .done, let address = record.funding.first?.address {
                            ForEach(record.leftover, id: \.txid) { leftover in
                                CaptionMText(t(
                                    "lightning__spark_exit__leftover",
                                    variables: ["amount": currency.primaryAmountText(sats: leftover.valueSats), "address": address]
                                ))
                                .padding(.top, 16)
                            }
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
            await exit.tick()
        }
        .task {
            await exit.tick()
        }
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
                isDone: record.phase == .done || (isFunded && record.claimableAtHeight == nil && !transactions.isEmpty)
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
