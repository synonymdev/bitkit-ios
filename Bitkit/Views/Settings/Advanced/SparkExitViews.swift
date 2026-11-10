import BitkitCore
import BreezSdkSpark
import SwiftUI

/// When to use an emergency exit, what it costs and how long it takes.
struct SparkExitIntroView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spark_exit__intro_title"), accentColor: .brandAccent)

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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_exit__quote_title"), accentColor: .brandAccent)
                        .padding(.bottom, 32)

                    if let quote = exit.quote {
                        SparkExitQuoteRows(quote: quote)

                        if let unexitableSats = SparkExitMath.unexitableSats(sparkBalanceSats: SparkManager.shared.balanceSats, quote: quote) {
                            BodySText(t(
                                "lightning__spark_exit__quote_outside",
                                variables: ["amount": currency.primaryAmountText(sats: unexitableSats)]
                            ))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitQuoteOutside")
                        }
                    } else if exit.isQuoting {
                        let key = SparkManager.shared.isSettlingForExit ? "lightning__spark_exit__quote_settling" : "lightning__spark_exit__quote_loading"
                        BodyMText(t(key))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let blockedReason {
                        BodyMText(blockedReason, textColor: .redAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitQuoteBlocked")
                    }
                }
                .padding(.bottom, 16)
            }

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

    /// What the funding address has to hold for the payments seen so far, and what the next one should bring it to.
    private var prestartFunding: (covered: UInt64, toSend: UInt64) {
        SparkExitMath.prestartFunding(
            fundingSats: fundingSats,
            payments: exit.fundingSeenCount,
            receivedSats: exit.fundingSeenSats,
            feeRate: exit.quoteFeeRate ?? 0
        )
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_exit__funding_title"), accentColor: .brandAccent)

                    BodyMText(
                        t("lightning__spark_exit__funding_text", variables: ["amount": currency.primaryAmountText(sats: fundingSats)]),
                        accentFont: Fonts.bold
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                    if let steps = exit.quote?.fundedSteps, steps > 1 {
                        BodySText(t("lightning__spark_exit__funding_split", variables: ["count": "\(steps)"]))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitFundingSplit")
                    }

                    if showsAddress, let address = exit.fundingAddress {
                        SparkExitFundingAddress(
                            address: address,
                            requiredSats: fundingSats,
                            receivedSats: exit.fundingSeenSats,
                            targetSats: prestartFunding.toSend
                        )
                        .padding(.top, 24)
                    }
                }
                .padding(.bottom, 16)
            }

            if showsAddress {
                CustomButton(title: t("common__continue")) {
                    exit.fundFromSavings = false
                    navigation.navigate(.sparkExitConfirm)
                }
                .disabled(exit.fundingSeenSats < prestartFunding.covered)
                .accessibilityIdentifier("SparkExitFundingContinue")
            } else {
                if hasSavingsFeeFailed || (savingsFeeSats != nil && !canFundFromSavings) {
                    BodySText(t("lightning__spark_exit__fund_insufficient"))
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
        let wallet = wallet
        let feeEstimatesManager = feeEstimatesManager
        let priced = await Self.priceSavingsFee(
            address: exit.fundingAddress,
            fundingSats: fundingSats,
            estimates: { await feeEstimatesManager.getEstimates(refresh: true) },
            calculate: { try await wallet.calculateTotalFee(address: $0, amountSats: $1, satsPerVByte: $2) }
        )
        switch priced {
        case .unavailable:
            break
        case .failed:
            hasSavingsFeeFailed = true
        case let .priced(rate, feeSats):
            exit.savingsFeeRate = rate
            exit.savingsFeeSats = feeSats
            savingsFeeSats = feeSats
        }
    }

    enum SavingsFee: Equatable {
        /// Nothing to price: no funding address or amount yet.
        case unavailable
        case failed
        case priced(rate: UInt32, feeSats: UInt64)
    }

    /// What savings pays to send the fee funding at the fast rate.
    nonisolated static func priceSavingsFee(
        address: String?,
        fundingSats: UInt64,
        estimates: () async -> FeeRates?,
        calculate: (String, UInt64, UInt32) async throws -> UInt64
    ) async -> SavingsFee {
        guard let address, fundingSats > 0 else { return .unavailable }
        // Without rates there is no fee to confirm: Pay from savings shows its error rather than loading for good.
        guard let feeRates = await estimates() else {
            Logger.warn("Failed to read fee rates for the Spark exit funding from savings", context: "SparkExitFundingView")
            return .failed
        }
        let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
        do {
            return try await .priced(rate: rate, feeSats: calculate(address, fundingSats, rate))
        } catch {
            Logger.warn("Failed to price the Spark exit funding from savings: \(error)", context: "SparkExitFundingView")
            return .failed
        }
    }
}

struct SparkExitFundingAddress: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    let address: String
    /// What the address asks for.
    let requiredSats: UInt64
    /// New funding already at the address, and the total it counts towards.
    let receivedSats: UInt64
    let targetSats: UInt64
    /// Off where the caller shows what was seen itself.
    var showsSeen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            QR(content: address)
                .frame(maxWidth: 200)
                .frame(maxWidth: .infinity)

            BodySText(t("lightning__spark_exit__fund_external_text", variables: ["amount": currency.primaryAmountText(sats: requiredSats)]))

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

            if let missingSats = SparkExitMath.partialFundingSats(receivedSats: receivedSats, requiredSats: targetSats) {
                BodySText(t("lightning__spark_exit__fund_partial", variables: [
                    "received": currency.primaryAmountText(sats: receivedSats),
                    "required": currency.primaryAmountText(sats: targetSats),
                    "missing": currency.primaryAmountText(sats: missingSats),
                ]))
                .accessibilityIdentifier("SparkExitFundingPartial")
            } else if showsSeen, receivedSats >= targetSats, targetSats > 0 {
                BodySText(t("lightning__spark_exit__fund_seen"), textColor: .greenAccent)
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
            BodySText(text)
            BodySText(t("lightning__spark_exit__funding_txid", variables: ["txid": txid]))
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

    private var path: String {
        SparkExitFundingKey.path(index: record.fundingIndex, network: Env.bitkitCoreNetwork)
    }

    /// One line with the total of every UTXO at the funding address, never one per UTXO, after what earlier sweeps sent.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(record.sweptLeftover ?? [], id: \.txid) { swept in
                BodySText(t("lightning__spark_exit__leftover_swept", variables: ["amount": currency.primaryAmountText(sats: swept.valueSats)]))
                BodySText(t("lightning__spark_exit__leftover_txid", variables: ["txid": swept.txid]))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            switch record.leftoverLine {
            case let .sending(sats, txid):
                BodySText(t("lightning__spark_exit__leftover_sending", variables: ["amount": currency.primaryAmountText(sats: sats)]))
                if let txid {
                    BodySText(t("lightning__spark_exit__leftover_txid", variables: ["txid": txid]))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            case let .swept(sats, txid):
                BodySText(t("lightning__spark_exit__leftover_swept", variables: ["amount": currency.primaryAmountText(sats: sats)]))
                BodySText(t("lightning__spark_exit__leftover_txid", variables: ["txid": txid]))
                    .lineLimit(2)
                    .truncationMode(.middle)
            case let .waiting(sats):
                BodySText(t("lightning__spark_exit__leftover_waiting", variables: ["amount": currency.primaryAmountText(sats: sats)]))
                    .fixedSize(horizontal: false, vertical: true)
            case let .kept(sats):
                BodySText(t("lightning__spark_exit__leftover_dust", variables: [
                    "amount": currency.primaryAmountText(sats: sats), "address": address, "path": path,
                ]))
                .fixedSize(horizontal: false, vertical: true)
            case let .rejected(sats):
                // Refused for good: where the coins stay, and the path that spends them with the recovery phrase.
                BodySText(t("lightning__spark_exit__leftover_rejected", variables: [
                    "amount": currency.primaryAmountText(sats: sats), "address": address, "path": path,
                ]))
                .fixedSize(horizontal: false, vertical: true)
            case let .stillAt(sats):
                BodySText(t("lightning__spark_exit__leftover", variables: ["amount": currency.primaryAmountText(sats: sats), "address": address]))
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_exit__confirm_title"), accentColor: .brandAccent)

                    BodyMText(t("lightning__spark_exit__confirm_text"), accentFont: Fonts.bold)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                        .padding(.bottom, 32)

                    if let quote = exit.quote {
                        SparkExitQuoteRows(quote: quote)
                    }

                    if let savingsPayment = exit.savingsPayment {
                        SparkExitAmountRow(label: t("lightning__spark_exit__savings_fee"), sats: savingsPayment.feeSats)
                        SparkExitAmountRow(label: t("lightning__spark_exit__savings_total"), sats: savingsPayment.totalSats)
                    }

                    SparkExitBackgroundNotes()
                        .padding(.top, 16)
                }
                .padding(.bottom, 16)
            }

            SwipeButton(title: t("lightning__spark_exit__swipe"), accentColor: .brandAccent) {
                do {
                    try await exit.start()
                    navigation.navigate(.sparkExitProgress)
                } catch let error as SparkExitStartCancelled {
                    // Cancelled while the start waited: nothing was paid, nothing to say. Rethrown so the swipe resets.
                    throw error
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
    @EnvironmentObject var app: AppViewModel
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

    /// Lost leaves are gone, so the text claims only what Spark still holds.
    private var failedText: String {
        if record?.isCancelled == true {
            return t("lightning__spark_exit__cancelled_text")
        }
        let staysSats = record.flatMap { SparkExitMath.staysOnSparkSats(sparkBalanceSats: SparkManager.shared.balanceSats, record: $0) }
        return [
            t("lightning__spark_exit__failed_text"),
            staysSats.map { t("lightning__spark_exit__failed_stays", variables: ["amount": currency.primaryAmountText(sats: $0)]) },
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// A top-up already paid, such as a higher fee's from savings, or seen at the address: nothing to ask for.
    private var isFundingOnItsWay: Bool {
        switch fundingState {
        case .paid, .seen: true
        default: false
        }
    }

    private var title: String {
        switch record?.phase {
        case .done: t("lightning__spark_exit__done_title")
        case .failed where record?.isCancelled == true: t("lightning__spark_exit__cancelled_title")
        case .failed: t("lightning__spark_exit__failed_title")
        case .needsFunding where !isFundingOnItsWay: t("lightning__spark_exit__needs_funding_title")
        default: t("lightning__spark_exit__progress_title")
        }
    }

    private var text: String {
        switch record?.phase {
        case .done:
            [
                // The amount that reached savings says it all; the generic line only stands in when it is unknown.
                record.flatMap(SparkExitMath.received).map {
                    t("lightning__spark_exit__done_received", variables: ["amount": currency.primaryAmountText(sats: $0.sats)])
                } ?? t("lightning__spark_exit__done_text"),
                (record?.skippedLeafCount ?? 0) > 0
                    ? t("lightning__spark_exit__partial_text", variables: ["count": "\(record?.skippedLeafCount ?? 0)"]) : nil,
                record.flatMap { $0.isFailedLeavesReleased == true && $0.failedLeavesSats > 0 ? $0.failedLeavesSats : nil }.map {
                    t("lightning__spark_exit__failed_leaves", variables: ["amount": currency.primaryAmountText(sats: $0)])
                },
            ].compactMap { $0 }.joined(separator: " ")
        case .failed: failedText
        case .needsFunding where !isFundingOnItsWay:
            t(
                "lightning__spark_exit__needs_funding_text",
                variables: ["amount": currency.primaryAmountText(sats: record.flatMap { SparkExitMath.neededSats($0, state: fundingState) } ?? 0)]
            )
        default: t("lightning__spark_exit__progress_text")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            DisplayText(title, accentColor: .brandAccent)
                .padding(.bottom, 16)

            BodyMText(text, accentFont: Fonts.bold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let record {
                        SparkExitSteps(record: record, tipHeight: exit.tipHeight)

                        if let sweepTxid = SparkExitMath.received(record)?.sweepTxid {
                            BodySText(t("lightning__spark_exit__sweep_txid", variables: ["txid": sweepTxid]))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitSweepTxid")
                        }

                        if record.isActive, record.isRebuiltFromChain == true {
                            BodySText(t("lightning__spark_exit__rebuilt_from_chain"))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitRebuiltFromChain")
                        }

                        if record.isActive, record.isWaitingForLeaves {
                            BodySText(t("lightning__spark_exit__waiting_leaves"))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitWaitingLeaves")
                        }

                        if record.isWaitingForOperators {
                            BodySText(t(
                                "lightning__spark_exit__waiting_operators",
                                variables: ["amount": currency.primaryAmountText(sats: record.failedLeavesSats)]
                            ))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitWaitingOperators")
                        }

                        if let address = record.funding.first?.address {
                            switch fundingState {
                            case let .ask(sats, receivedSats):
                                // The ask counts the input fee of each payment, so it is what is missing; the hint
                                // names the full total, not the dust-floored ask added to what arrived.
                                SparkExitFundingAddress(
                                    address: address,
                                    requiredSats: sats,
                                    receivedSats: receivedSats,
                                    targetSats: exit.fundingAskTotal ?? sats + receivedSats,
                                    showsSeen: false
                                )
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

                        if record.leftBehindSats > 0 {
                            BodySText(t(
                                "lightning__spark_exit__left_behind_leaves",
                                variables: ["amount": currency.primaryAmountText(sats: record.leftBehindSats)]
                            ))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitLeftBehind")
                        }

                        if let lostText {
                            BodySText(lostText, textColor: .redAccent)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitLostLeaves")
                        }

                        if record.isActive, let rejection = record.surfacedRejection {
                            BodySText(t("lightning__spark_exit__not_moving", variables: ["error": rejection]), textColor: .redAccent)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitNotMoving")
                        }

                        if record.showsFeeLow(tip: exit.tipHeight) {
                            BodySText(t("lightning__spark_exit__fee_low", variables: ["rate": "\(record.feeRateSatPerVbyte)"]))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitFeeLow")
                        } else if exit.canPayHigherFee {
                            Button {
                                navigation.navigate(.sparkExitFeeBump)
                            } label: {
                                BodySText(t("lightning__spark_exit__fee_rose"), textColor: .yellowAccent)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitFeeRose")
                        }

                        if let outsideSats = SparkExitMath.outsideExitSats(sparkBalanceSats: SparkManager.shared.balanceSats, record: record) {
                            BodySText(t(
                                "lightning__spark_exit__outside_exit",
                                variables: ["amount": currency.primaryAmountText(sats: outsideSats)]
                            ))
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitOutsideExit")
                        }

                        if exit.isSavingsPaymentRefused {
                            BodySText(t("lightning__spark_exit__savings_refused"), textColor: .redAccent)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitSavingsRefused")
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

            if exit.isSavingsPaymentRefused {
                CustomButton(title: t("lightning__spark_exit__fund_savings"), variant: .secondary) {
                    do {
                        try await exit.retrySavingsPayment()
                    } catch {
                        app.toast(error)
                    }
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("SparkExitRetrySavings")
            }

            if exit.canPayHigherFee {
                CustomButton(title: t("lightning__spark_exit__fee_bump_button"), variant: .secondary) {
                    navigation.navigate(.sparkExitFeeBump)
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("SparkExitFeeBump")
            }

            if exit.canCancel {
                CustomButton(title: t("lightning__spark_exit__cancel"), variant: .secondary) {
                    // A funding address that cannot be read keeps the exit: a payment there is never orphaned.
                    if await exit.cancel() == .keep {
                        app.toast(type: .error, title: t("lightning__spark_exit__cancel_failed"), description: nil)
                    } else {
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
        .task(id: record?.hasUnseenResult) {
            exit.markResultSeen()
        }
    }
}

/// Moves a running exit to a higher fee rate: each rate with what it costs from savings, then pays the extra fee
/// funding and rebuilds what has not confirmed, which replaces it on the network.
struct SparkExitFeeBumpView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var selectedRate: UInt64?
    @State private var savingsFeeRate: UInt32?
    @State private var isPaying = false

    private let exit = SparkExitManager.shared

    private var selected: SparkExitFeeBumpOption? {
        exit.feeBumpOptions.first { $0.rate == selectedRate }
    }

    private func canPay(_ option: SparkExitFeeBumpOption) -> Bool {
        guard let total = option.totalSats else { return false }
        return total == 0 || UInt64(max(0, wallet.spendableOnchainBalanceSats)) >= total
    }

    /// Savings can't pay the selected rate, or, with none selected, any rate priced so far.
    private var isInsufficient: Bool {
        if let selected {
            return selected.totalSats != nil && !canPay(selected)
        }
        let priced = exit.feeBumpOptions.filter { $0.totalSats != nil }
        return !priced.isEmpty && !priced.contains(where: canPay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_exit__fee_bump_title"), accentColor: .brandAccent)

                    BodyMText(
                        t("lightning__spark_exit__fee_bump_text", variables: ["rate": "\(exit.record?.feeRateSatPerVbyte ?? 0)"]),
                        accentFont: Fonts.bold
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .padding(.bottom, 24)

                    if exit.isPricingFeeBump {
                        BodyMText(t("lightning__spark_exit__fee_bump_loading"))
                    } else if let error = exit.feeBumpError {
                        BodyMText(error, textColor: .redAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("SparkExitFeeBumpError")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(exit.feeBumpOptions) { option in
                                FeeItem(
                                    title: option.speed.title,
                                    subtitle: "\(option.speed.range) · \(option.rate) sat/vB",
                                    iconName: option.speed.iconName,
                                    iconColor: option.speed.iconColor,
                                    amount: option.totalSats ?? 0,
                                    isSelected: option.rate == selectedRate,
                                    isDisabled: !canPay(option)
                                ) {
                                    selectedRate = option.rate
                                }
                                .accessibilityIdentifier("SparkExitFeeBumpRate-\(option.rate)")
                            }
                        }
                        .padding(.horizontal, -16)
                    }
                }
                .padding(.bottom, 16)
            }

            if isInsufficient {
                BodySText(t("lightning__spark_exit__fund_insufficient"))
                    .padding(.bottom, 16)
                    .accessibilityIdentifier("SparkExitFeeBumpInsufficient")
            }

            CustomButton(
                title: t(selected?.extraSats == 0 ? "lightning__spark_exit__fee_bump_confirm" : "lightning__spark_exit__fund_savings"),
                isLoading: isPaying || exit.isPricingFeeBump
            ) {
                await pay()
            }
            .disabled(selected.map { !canPay($0) } ?? true)
            .accessibilityIdentifier("SparkExitFeeBumpPay")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await exit.loadFeeBumpOptions()
            await priceSavingsPayments()
            selectedRate = exit.feeBumpOptions.first(where: canPay)?.rate
        }
    }

    /// What savings pays in fees to send each option's extra funding, at its fast rate.
    private func priceSavingsPayments() async {
        guard let address = exit.record?.funding.first?.address,
              let feeRates = await feeEstimatesManager.getEstimates(refresh: true)
        else { return }
        let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
        savingsFeeRate = rate
        for option in exit.feeBumpOptions {
            guard let extraSats = option.extraSats, extraSats > 0 else { continue }
            do {
                let fee = try await wallet.calculateTotalFee(address: address, amountSats: extraSats, satsPerVByte: rate)
                exit.setFeeBumpPaymentFee(rate: option.rate, sats: fee)
            } catch {
                // Savings can't send it, usually because it doesn't hold enough: the option stays unpriced and disabled.
                Logger.warn("Failed to price a Spark exit fee bump payment: \(error)", context: "SparkExitFeeBumpView")
            }
        }
    }

    private func pay() async {
        guard let selected else { return }
        isPaying = true
        defer { isPaying = false }
        do {
            try await exit.payHigherFee(selected, savingsFeeRate: savingsFeeRate ?? 1)
            navigation.navigateBack()
        } catch {
            app.toast(error)
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
                BodySText(note)
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

    /// The exit's own steps all landed: done, or only leaves the operators moved on-chain are left.
    private var isLanded: Bool {
        record.phase == .done || record.isRetryingFailedLeaves
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(t("lightning__spark_exit__step_funding"), isDone: isFunded)
            step(
                t("lightning__spark_exit__step_publish"),
                detail: record.recovery.map { "\(SparkExitMath.confirmedCount($0.response))/\(transactions.count)" },
                isDone: isLanded
            )
            step(
                t("lightning__spark_exit__step_timelock"),
                detail: remainingDuration.map { t("lightning__spark_exit__ready_in", variables: ["duration": $0]) },
                isDone: isLanded || SparkExitMath.areTimelocksMatured(transactions)
            )
            step(t("lightning__spark_exit__step_sweep"), isDone: isLanded)
        }
    }

    private func step(_ title: String, detail: String? = nil, isDone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(isDone ? "check-mark" : "hourglass-simple")
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
