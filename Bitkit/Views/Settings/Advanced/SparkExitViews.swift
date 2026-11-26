import BitkitCore
import BreezSdkSpark
import SwiftUI

/// Asks whether to force transfer the spending balance to savings, and for how long it is out of reach.
struct SparkExitIntroView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            Spacer()

            Image("exclamation-mark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 256, maxHeight: 256)
                .frame(maxWidth: .infinity)

            Spacer()

            DisplayText(t("lightning__spark_exit__intro_title"), accentColor: .yellowAccent)

            BodyMText(t("lightning__spark_exit__intro_text"), accentFont: Fonts.bold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SparkExitLayout.headlineGap)
                .padding(.bottom, 32)

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

/// What the force transfer moves, what the network takes, and what reaches savings.
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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_exit__quote_title"), accentColor: .yellowAccent)

                    BodyMText(t("lightning__spark_exit__quote_text"), accentFont: Fonts.bold)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SparkExitLayout.headlineGap)
                        .padding(.bottom, 32)

                    if let quote = exit.quote {
                        SparkExitQuoteRows(quote: quote)
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
                .padding(.bottom, 32)
            }

            HStack(spacing: 16) {
                CustomButton(title: t("common__cancel"), variant: .secondary) {
                    navigation.navigateBack()
                }

                CustomButton(title: t("common__continue"), isLoading: exit.isQuoting) {
                    guard let quote = exit.quote else { return }
                    navigation.navigate(quote.fundingSats > 0 ? .sparkExitFunding : .sparkExitConfirm)
                }
                .disabled(exit.quote == nil || blockedReason != nil)
                .accessibilityIdentifier("SparkExitQuoteContinue")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await exit.loadQuote()
        }
    }
}

/// The caption heading a table of a force transfer screen.
struct SparkExitHeader: View {
    let text: String

    var body: some View {
        CaptionMText(text)
            .padding(.vertical, 16)
    }
}

/// What the transfer moves, what the network takes and what reaches savings.
struct SparkExitQuoteRows: View {
    let quote: SparkExitQuote

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkExitHeader(text: t("lightning__spark_exit__overview"))
            SparkExitAmountRow(label: t("lightning__spark_exit__amount"), sats: quote.exitSats)
            SparkExitAmountRow(label: t("lightning__spark_exit__fees"), sats: quote.networkFeeSats)
            SparkExitAmountRow(label: t("lightning__spark_exit__receive"), sats: quote.receiveSats)
        }
    }
}

/// The emergency fees: one total, from savings or from another wallet.
struct SparkExitFeesRow: View {
    let label: String
    let sats: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkExitHeader(text: t("lightning__spark_exit__fees_header"))
            SparkExitAmountRow(label: label, sats: sats)
        }
    }
}

struct SparkExitAmountRow: View {
    let label: String
    let sats: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                CaptionBText(label, textColor: .textPrimary)
                Spacer()
                // Always in bitcoin, with no exchange rate needed: the user may have to send exactly this amount.
                MoneyText(sats: Int(sats), forceUnit: .bitcoin, size: .captionB, symbol: true)
            }
            .frame(height: 50)
            CustomDivider()
        }
    }
}

/// The emergency fees the force transfer pays on-chain: from savings when it can cover them, else from another wallet.
struct SparkExitFundingView: View {
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var savingsFeeSats: UInt64?
    /// Savings can't pay the funding, usually because it doesn't hold enough.
    @State private var hasSavingsFeeFailed = false
    /// A payment already reached the funding address, read once on entry: another wallet pays.
    @State private var showsFundingAddress = false
    @State private var isReadingFundingAddress = true

    private let exit = SparkExitManager.shared

    private var fundingSats: UInt64 {
        exit.quote?.fundingSats ?? 0
    }

    /// What savings pays: the funding less what another wallet already sent to the address, plus the savings
    /// payment's own input fee then, as the start pays it.
    private var savingsSats: UInt64 {
        exit.savingsSats
    }

    private var canFundFromSavings: Bool {
        guard let savingsFeeSats else { return false }
        return SparkExitMath.canFundFromSavings(
            spendableSats: UInt64(max(0, wallet.spendableOnchainBalanceSats)),
            fundingSats: savingsSats,
            paymentFeeSats: savingsFeeSats,
            readsBitkitChain: SparkManager.shared.canFundFromChain
        )
    }

    private var isPricingSavings: Bool {
        Self.isPricingSavings(savingsFeeSats: savingsFeeSats, hasSavingsFeeFailed: hasSavingsFeeFailed)
    }

    private var paysExternally: Bool {
        Self.paysExternally(
            showsFundingAddress: showsFundingAddress,
            isPricingSavings: isPricingSavings,
            canFundFromSavings: canFundFromSavings
        )
    }

    /// What would leave savings to pay the fee funding: the funding and the fee of the payment that sends it.
    private var savingsCostSats: UInt64? {
        guard savingsSats > 0, let savingsFeeSats else { return nil }
        return savingsSats + savingsFeeSats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__nav_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_exit__fees_title"), accentColor: .yellowAccent)

                    BodyMText(t("lightning__spark_exit__fees_text"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SparkExitLayout.headlineGap)

                    if paysExternally {
                        SparkExitFeesRow(label: t("lightning__spark_exit__fees_other_wallet"), sats: fundingSats)
                            .padding(.top, 32)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("SparkExitFeesExternal")
                    } else if let savingsCostSats {
                        SparkExitFeesRow(label: t("lightning__spark_exit__fees_savings_note"), sats: savingsCostSats)
                            .padding(.top, 32)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("SparkExitFeesSavings")
                    }

                    if paysExternally || savingsCostSats != nil {
                        BodySText(t("lightning__spark_exit__fees_unused"))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 32)
                    }
                }
                .padding(.bottom, 32)
            }

            HStack(spacing: 16) {
                CustomButton(title: t("common__cancel"), variant: .secondary) {
                    navigation.navigateBack()
                }

                CustomButton(
                    title: t("common__continue"),
                    isLoading: isReadingFundingAddress || (isPricingSavings && !showsFundingAddress)
                ) {
                    exit.fundFromSavings = !paysExternally
                    navigation.navigate(paysExternally ? .sparkExitPay : .sparkExitConfirm)
                }
                .accessibilityIdentifier("SparkExitFundingContinue")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            exit.fundFromSavings = false
            isReadingFundingAddress = true
            let seenSats = await exit.readFundingAddress()
            showsFundingAddress = (seenSats ?? 0) > 0
            isReadingFundingAddress = false
        }
        .task(id: savingsSats) {
            await estimateSavingsFee()
        }
    }

    private func estimateSavingsFee() async {
        savingsFeeSats = nil
        hasSavingsFeeFailed = false
        let wallet = wallet
        let feeEstimatesManager = feeEstimatesManager
        let priced = await Self.priceSavingsFee(
            address: exit.fundingAddress,
            fundingSats: savingsSats,
            refusedFeeSats: exit.savingsFundingRefusedFeeSats,
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

    /// Savings is still being priced for the fee funding.
    nonisolated static func isPricingSavings(savingsFeeSats: UInt64?, hasSavingsFeeFailed: Bool) -> Bool {
        savingsFeeSats == nil && !hasSavingsFeeFailed
    }

    /// Another wallet pays the emergency fees: once a payment reached the funding address, or when savings cannot
    /// cover them.
    nonisolated static func paysExternally(showsFundingAddress: Bool, isPricingSavings: Bool, canFundFromSavings: Bool) -> Bool {
        showsFundingAddress || (!isPricingSavings && !canFundFromSavings)
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
        refusedFeeSats: UInt64? = nil,
        estimates: () async -> FeeRates?,
        calculate: (String, UInt64, UInt32) async throws -> UInt64
    ) async -> SavingsFee {
        guard let address, fundingSats > 0 else { return .unavailable }
        // Without rates there is no fee to confirm: the fees screen goes on to another wallet rather than loading for good.
        guard let feeRates = await estimates() else {
            Logger.warn("Failed to read fee rates for the Spark exit funding from savings", context: "SparkExitFundingView")
            return .failed
        }
        let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
        do {
            // Coin selection can need more fee than the estimate: after a refused start, at least the fee it asked.
            let feeSats = try await calculate(address, fundingSats, rate)
            return .priced(rate: rate, feeSats: max(feeSats, refusedFeeSats ?? 0))
        } catch {
            Logger.warn("Failed to price the Spark exit funding from savings: \(error)", context: "SparkExitFundingView")
            return .failed
        }
    }
}

/// The emergency fees paid from another wallet to the funding address: the force transfer starts on its own once the
/// funding address holds them, on entry too; a failed start shows Try again.
struct SparkExitPayView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    /// The funding address was read this visit, so what it holds is current.
    @State private var hasReadFunding = false
    /// A start ran this visit, on its own or from a tap: a failed one shows its error and waits for a tap, never
    /// retrying by itself.
    @State private var hasAutoStarted = false
    @State private var isStarting = false

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

    private var isFunded: Bool {
        exit.fundingSeenSats >= prestartFunding.covered
    }

    private var canAutoStart: Bool {
        SparkExitMath.canAutoStartFunding(
            isFunded: isFunded,
            isStarting: isStarting,
            hasAutoStarted: hasAutoStarted,
            hasReadFunding: hasReadFunding
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A running start cannot be left: it would go on and open Progress anyway.
            NavigationBar(title: t("lightning__spark_exit__nav_title"), showBackButton: !isStarting, showMenuButton: !isStarting)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_exit__pay_title"), accentColor: .yellowAccent)

                    BodyMText(t("lightning__spark_exit__pay_text"), accentFont: Fonts.bold)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SparkExitLayout.headlineGap)

                    SparkExitFeesRow(label: t("lightning__spark_exit__pay_amount"), sats: fundingSats)
                        .padding(.top, 32)

                    if let address = exit.fundingAddress {
                        SparkExitFundingAddress(address: address, receivedSats: exit.fundingSeenSats, targetSats: prestartFunding.toSend)
                            .padding(.top, 32)
                    }
                }
                .padding(.bottom, 32)
            }

            // A failed start offers Try again. A start can wait minutes for Spark, so its button spins until it ends.
            if isStarting || (isFunded && hasAutoStarted) {
                CustomButton(title: t("common__try_again"), isLoading: isStarting) {
                    start()
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("SparkExitPayRetry")
            }

            CustomButton(title: t("common__cancel"), variant: .secondary, isDisabled: isStarting) {
                navigation.navigateBack()
            }
            .accessibilityIdentifier("SparkExitPayCancel")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            hasReadFunding = false
            hasAutoStarted = false
            await exit.watchFundingAddress {
                hasReadFunding = true
            }
        }
        .onChange(of: canAutoStart) { _, canAutoStart in
            guard canAutoStart else { return }
            hasAutoStarted = true
            start()
        }
    }

    /// Claims the one start this screen runs at a time before its task begins, so neither a tap nor the funding can
    /// launch a second.
    private func start() {
        guard !isStarting else { return }
        isStarting = true
        SwipeBackState.allowSwipeBack = false
        exit.fundFromSavings = false
        // Asked as the force transfer starts: the reminders are how Bitkit reaches the user when a step needs the app.
        PushNotificationManager.shared.requestPermissionIfUndecided()
        Task {
            do {
                try await startSparkExit(app: app, navigation: navigation)
            } catch {
                // Still here: swipe back again. A start that opened Progress leaves the gesture to it, which blocks it.
                SwipeBackState.allowSwipeBack = true
            }
            isStarting = false
        }
    }
}

/// The funding address to pay from another wallet, with its copy button and what arrived so far.
struct SparkExitFundingAddress: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    let address: String
    /// New funding already at the address, and the total it counts towards.
    let receivedSats: UInt64
    let targetSats: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkExitHeader(text: t("lightning__spark_exit__send_to_address"))

            CaptionBText(address, textColor: .textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityIdentifier("SparkExitFundingAddress")

            CustomButton(
                title: t("lightning__spark_exit__copy_address"),
                size: .small,
                icon: Image("copy").resizable().frame(width: 16, height: 16).foregroundColor(.yellowAccent)
            ) {
                UIPasteboard.general.string = address
                Haptics.play(.copiedToClipboard)
                app.toast(type: .success, title: t("common__copied"), description: address)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .accessibilityIdentifier("SparkExitCopyAddress")

            if let missingSats = SparkExitMath.partialFundingSats(receivedSats: receivedSats, requiredSats: targetSats) {
                BodySText(t("lightning__spark_exit__fund_partial", variables: [
                    "received": sparkExitAmountAccent(currency.bitcoinAmountText(sats: receivedSats)),
                    "required": sparkExitAmountAccent(currency.bitcoinAmountText(sats: targetSats)),
                    "missing": sparkExitAmountAccent(currency.bitcoinAmountText(sats: missingSats)),
                ]), accentColor: .white, accentFont: Fonts.bold)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .accessibilityIdentifier("SparkExitFundingPartial")
            }
        }
    }
}

/// Starts the force transfer for the quote on screen and opens its progress. A start that failed after the transfer
/// began, such as its savings payment, opens progress too, which shows where to pay the emergency fees.
@MainActor
func startSparkExit(app: AppViewModel, navigation: NavigationViewModel) async throws {
    let exit = SparkExitManager.shared
    do {
        try await exit.start()
        navigation.openSparkExitProgress()
    } catch let error as SparkExitStartCancelled {
        // Cancelled while the start waited: nothing was paid, nothing to say.
        throw error
    } catch {
        if case let OnchainSendAttemptError.preDispatch(refused) = error, let changed = refused as? SparkFundingChanged {
            // Savings never pays more than the fee confirmed: the next funding asks for the refused one.
            exit.noteSavingsFundingRefused(preparedFeeSats: changed.preparedFeeSats)
            app.toast(type: .info, title: t("lightning__spending_confirm__fees_changed_title"))
        } else {
            app.toast(error)
        }
        if exit.isExiting {
            navigation.openSparkExitProgress()
            return
        }
        throw error
    }
}

/// The amount marked as an inline accent: bold white on a grey line, bold red on a red one.
func sparkExitAmountAccent(_ amount: String) -> String {
    "<accent>\(amount)</accent>"
}

/// A line of progress with the transaction it is about, in the activity explore cell whose id copies on tap.
struct SparkExitTxNote: View {
    let text: String
    let txid: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BodySText(text, accentColor: .white, accentFont: Fonts.bold)
                .fixedSize(horizontal: false, vertical: true)
            ActivityInfoSection(title: t("wallet__activity_tx_id"), content: txid, usesCustomDivider: true, bottomSpacing: 0)
                .padding(.top, 16)
        }
    }
}

/// Where the ended exit's leftover fee funding is: on its way to savings, sent, or too small to send. Once the returned
/// note counts what the sweeps sent back, it names only funding that has not reached savings yet.
struct SparkExitLeftoverStatus: View {
    @EnvironmentObject var currency: CurrencyViewModel

    let record: SparkExitRecord
    let address: String
    /// The returned note shows the unused fees, confirmed sweeps included, so their lines would repeat it.
    var isSweptCounted = false

    private var path: String {
        SparkExitFundingKey.path(index: record.fundingIndex, network: Env.bitkitCoreNetwork)
    }

    /// The line to show: none for a confirmed sweep the returned note already counts.
    private var line: SparkExitRecord.LeftoverLine? {
        switch record.leftoverLine {
        case .swept: isSweptCounted ? nil : record.leftoverLine
        default: record.leftoverLine
        }
    }

    /// What earlier sweeps sent back, unless the returned note already counts it.
    private var sweptEarlier: [SparkExitRecord.SweptLeftover] {
        isSweptCounted ? [] : record.sweptLeftover ?? []
    }

    /// One line with the total of every UTXO at the funding address, never one per UTXO, after what earlier sweeps sent.
    var body: some View {
        if line != nil || !sweptEarlier.isEmpty {
            lines
                .padding(.top, 16)
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sweptEarlier, id: \.txid) { swept in
                SparkExitTxNote(
                    text: t("lightning__spark_exit__leftover_swept",
                            variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: swept.valueSats))]),
                    txid: swept.txid
                )
            }
            switch line {
            case let .sending(sats, txid):
                if let txid {
                    SparkExitTxNote(
                        text: t("lightning__spark_exit__leftover_sending",
                                variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: sats))]),
                        txid: txid
                    )
                } else {
                    BodySText(
                        t(
                            "lightning__spark_exit__leftover_sending",
                            variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: sats))]
                        ),
                        accentColor: .white,
                        accentFont: Fonts.bold
                    )
                }
            case let .swept(sats, txid):
                SparkExitTxNote(
                    text: t("lightning__spark_exit__leftover_swept",
                            variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: sats))]),
                    txid: txid
                )
            case let .waiting(sats):
                BodySText(
                    t("lightning__spark_exit__leftover_waiting",
                      variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: sats))]),
                    accentColor: .white,
                    accentFont: Fonts.bold
                )
                .fixedSize(horizontal: false, vertical: true)
            case let .kept(sats):
                BodySText(t("lightning__spark_exit__leftover_dust", variables: [
                    "amount": sparkExitAmountAccent(currency.primaryAmountText(sats: sats)), "address": address, "path": path,
                ]), accentColor: .white, accentFont: Fonts.bold)
                    .fixedSize(horizontal: false, vertical: true)
            case let .rejected(sats):
                // Refused for good: where the coins stay, and the path that spends them with the recovery phrase.
                BodySText(t("lightning__spark_exit__leftover_rejected", variables: [
                    "amount": sparkExitAmountAccent(currency.primaryAmountText(sats: sats)), "address": address, "path": path,
                ]), accentColor: .white, accentFont: Fonts.bold)
                    .fixedSize(horizontal: false, vertical: true)
            case let .stillAt(sats):
                BodySText(
                    t("lightning__spark_exit__leftover", variables: [
                        "amount": sparkExitAmountAccent(currency.primaryAmountText(sats: sats)),
                        "address": address,
                    ]),
                    accentColor: .white,
                    accentFont: Fonts.bold
                )
                .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SparkExitLeftover")
    }
}

/// The last look before the force transfer starts: what reaches savings and what savings pays for it.
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
                    DisplayText(t("lightning__spark_exit__confirm_title"), accentColor: .yellowAccent)
                        .padding(.bottom, 32)

                    if let quote = exit.quote {
                        SparkExitQuoteRows(quote: quote)
                    }

                    if let savingsPayment = exit.savingsPayment {
                        SparkExitFeesRow(label: t("lightning__spark_exit__fees_savings"), sats: savingsPayment.totalSats)
                            .padding(.top, 32)
                    }
                }
                .padding(.bottom, 32)
            }

            SwipeButton(title: t("lightning__spark_exit__swipe"), accentColor: .yellowAccent) {
                try await startSparkExit(app: app, navigation: navigation)
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

/// The running force transfer's steps, and its result once it ends.
struct SparkExitProgressView: View {
    @EnvironmentObject var app: AppViewModel
    @ObservedObject private var notifications = PushNotificationManager.shared
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var wallet: WalletViewModel

    private let exit = SparkExitManager.shared
    @State private var isConfirmingCancel = false
    /// The start's savings payment, refused before it went out for a higher fee, priced again at the new fee.
    @State private var savingsRetry: (rate: UInt32, feeSats: UInt64)?
    @State private var isPayingSavings = false

    private var record: SparkExitRecord? {
        exit.record
    }

    private var savingsRefusal: SparkExitRecord.SavingsRefusal? {
        record.flatMap {
            SparkExitManager.savingsRefusal(
                $0,
                fundingState: fundingState,
                hasSavingsSend: exit.hasSavingsSend,
                fundingSeenSats: exit.fundingSeenSats
            )
        }
    }

    /// What leaves savings for the refused payment at its new fee, while savings can cover it: the fee to confirm.
    private var savingsRetryTotalSats: UInt64? {
        // A price below the refused fee is from before the latest refusal.
        guard let savingsRefusal, let savingsRetry, savingsRetry.feeSats >= savingsRefusal.feeSats,
              SparkExitMath.canFundFromSavings(
                  spendableSats: UInt64(max(0, wallet.spendableOnchainBalanceSats)),
                  fundingSats: savingsRefusal.sats,
                  paymentFeeSats: savingsRetry.feeSats,
                  // Paid by the node alone, to an address the exit already holds: Spark need not be connected.
                  readsBitkitChain: SparkManager.shared.readsSavingsChain
              )
        else { return nil }
        return savingsRefusal.sats + savingsRetry.feeSats
    }

    /// Progress says the savings payment didn't go through and offers to pay it again.
    private var offersSavingsRetry: Bool {
        exit.isSavingsPaymentRefused || savingsRetryTotalSats != nil
    }

    /// Prices the refused payment, again every 15 seconds after a failed price, such as before the node runs, while
    /// progress can still offer it.
    private func priceSavingsRetry() async {
        // No refusal to offer: an older price is never offered for a later one.
        guard savingsRefusal != nil else {
            savingsRetry = nil
            return
        }
        while !Task.isCancelled, savingsRefusal != nil {
            if await priceSavingsRetryOnce() {
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    /// A failed price keeps the last one, which is never offered below a fee refused since. Whether it priced the
    /// refusal progress offers now.
    @discardableResult
    private func priceSavingsRetryOnce() async -> Bool {
        guard let savingsRefusal, let address = record?.funding.first?.address else {
            savingsRetry = nil
            return false
        }
        let wallet = wallet
        let feeEstimatesManager = feeEstimatesManager
        let priced = await SparkExitFundingView.priceSavingsFee(
            address: address,
            fundingSats: savingsRefusal.sats,
            refusedFeeSats: savingsRefusal.feeSats,
            estimates: { await feeEstimatesManager.getEstimates(refresh: true) },
            calculate: { try await wallet.calculateTotalFee(address: $0, amountSats: $1, satsPerVByte: $2) }
        )
        // A cancelled price, or one for a refusal since replaced, changes nothing.
        guard !Task.isCancelled, self.savingsRefusal == savingsRefusal, case let .priced(rate, feeSats) = priced else {
            return false
        }
        savingsRetry = (rate, feeSats)
        return true
    }

    private var fundingState: SparkExitFundingState? {
        guard let record, record.fundingShortfallSats != nil else { return nil }
        return exit.fundingState ?? SparkExitMath.fundingState(record, utxos: nil)
    }

    private var lostText: String? {
        guard let record, record.lostSats > 0 else { return nil }
        return t(
            "lightning__spark_exit__lost_leaves",
            variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: record.lostSats))]
        )
    }

    /// Lost leaves are gone, so the text claims only what Spark still holds.
    private var failedText: String {
        if record?.isCancelled == true {
            return t("lightning__spark_exit__cancelled_text")
        }
        let staysSats = record.flatMap { SparkExitMath.staysOnSparkSats(sparkBalanceSats: SparkManager.shared.balanceSats, record: $0) }
        return [
            t("lightning__spark_exit__failed_text"),
            staysSats.map { t(
                "lightning__spark_exit__failed_stays",
                variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: $0))]
            ) },
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
                t("lightning__spark_exit__done_text"),
                record.flatMap { $0.isFailedLeavesReleased == true && $0.failedLeavesSats > 0 ? $0.failedLeavesSats : nil }.map {
                    t("lightning__spark_exit__failed_leaves", variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: $0))])
                },
            ].compactMap { $0 }.joined(separator: " ")
        case .failed: failedText
        case .needsFunding where !isFundingOnItsWay:
            t(
                "lightning__spark_exit__needs_funding_text",
                variables: ["amount": currency.bitcoinAmountText(sats: record.flatMap { SparkExitMath.neededSats($0, state: fundingState) } ?? 0)]
            )
        default: t("lightning__spark_exit__progress_text")
        }
    }

    /// What the ended force transfer returned to savings: the spending balance and the emergency fees it did not spend.
    private var returnedText: String? {
        guard let record, let returned = SparkExitMath.returned(record), returned.spendingSats > 0 else { return nil }
        let amount = currency.primaryAmountText(sats: returned.spendingSats)
        let feesSats = returned.feesSats
        guard feesSats > 0 else { return t("lightning__spark_exit__done_returned", variables: ["amount": amount]) }
        return t(
            "lightning__spark_exit__done_returned_fees",
            variables: ["amount": amount, "fees": currency.primaryAmountText(sats: feesSats)]
        )
    }

    /// The returned note names the unused emergency fees, so a done exit's confirmed sweeps are counted there.
    private var isReturnedFeesShown: Bool {
        guard let record, record.phase == .done, let returned = SparkExitMath.returned(record) else { return false }
        return returned.spendingSats > 0 && returned.feesSats > 0
    }

    private var isFailedOrMissing: Bool {
        switch record?.phase {
        case .failed, nil: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_exit__progress_nav_title"), showBackButton: false)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(title, accentColor: .yellowAccent)

                    BodyMText(text, accentFont: Fonts.bold)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SparkExitLayout.headlineGap)
                        .padding(.bottom, 32)

                    if let record {
                        SparkExitSteps(record: record)

                        if let returnedText {
                            BodySText(returnedText, accentColor: .white, accentFont: Fonts.bold)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 32)
                                .accessibilityIdentifier("SparkExitReturned")
                        }

                        if offersSavingsRetry {
                            BodySText(t("lightning__spark_exit__savings_refused"), textColor: .redAccent)
                                .padding(.top, 24)
                                .accessibilityIdentifier("SparkExitSavingsRefused")
                        }

                        if let address = record.funding.first?.address {
                            switch fundingState {
                            case let .ask(sats, receivedSats):
                                // The ask counts the input fee of each payment, so it is what is missing; the hint
                                // names the full total, not the dust-floored ask added to what arrived.
                                SparkExitFeesRow(label: t("lightning__spark_exit__pay_amount"), sats: sats)
                                    .padding(.top, 24)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("SparkExitProgressFundingAmount")
                                // The new fee to confirm: what leaves savings once Pay from savings is tapped.
                                if let savingsRetryTotalSats {
                                    SparkExitAmountRow(label: t("lightning__spark_exit__fees_savings"), sats: savingsRetryTotalSats)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("SparkExitProgressSavingsTotal")
                                }
                                SparkExitFundingAddress(
                                    address: address,
                                    receivedSats: receivedSats,
                                    targetSats: exit.fundingAskTotal ?? sats + receivedSats
                                )
                                .padding(.top, 32)
                            case .paid, .seen, nil:
                                EmptyView()
                            }
                        }

                        if record.isActive, record.isRebuiltFromChain == true {
                            BodySText(t("lightning__spark_exit__rebuilt_from_chain"))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitRebuiltFromChain")
                        }

                        if record.isWaitingForOperators {
                            BodySText(t(
                                "lightning__spark_exit__waiting_operators",
                                variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: record.failedLeavesSats))]
                            ), accentColor: .white, accentFont: Fonts.bold)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitWaitingOperators")
                        }

                        if record.isActive, record.isWaitingForLeaves {
                            BodySText(t("lightning__spark_exit__waiting_leaves"))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitWaitingLeaves")
                        }

                        if let rejection = record.surfacedRejection {
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.top, 16)
                            .accessibilityIdentifier("SparkExitFeeRose")
                        }

                        if let lostText {
                            BodySText(lostText, textColor: .redAccent, accentColor: .redAccent, accentFont: Fonts.bold)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitLostLeaves")
                        }

                        if record.leftBehindSats > 0 {
                            BodySText(t(
                                "lightning__spark_exit__left_behind_leaves",
                                variables: ["amount": sparkExitAmountAccent(currency.primaryAmountText(sats: record.leftBehindSats))]
                            ), accentColor: .white, accentFont: Fonts.bold)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 16)
                                .accessibilityIdentifier("SparkExitLeftBehind")
                        }

                        if record.isActive {
                            SparkExitBackgroundNotes()
                                .padding(.top, 16)
                        }

                        if !record.isActive, let address = record.funding.first?.address {
                            SparkExitLeftoverStatus(record: record, address: address, isSweptCounted: isReturnedFeesShown)
                        }
                    }
                }
                .padding(.bottom, 32)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SparkExitProgress")
            }
            .refreshable {
                await SparkManager.shared.refreshState()
                await exit.tick()
                await priceSavingsRetryOnce()
            }
            // Over the bottom inset: content cut at the edge fades out above the buttons, and scrolled to the end the
            // last line clears it.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.customBlack.opacity(0), .customBlack], startPoint: .top, endPoint: .bottom)
                    .frame(height: 32)
                    .allowsHitTesting(false)
            }

            if record?.isActive == true, notifications.authorizationStatus == .denied {
                CustomButton(title: t("lightning__spark_exit__note_notifications_button"), variant: .secondary) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        await UIApplication.shared.open(url)
                    }
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("SparkExitNotificationSettings")
            }

            if offersSavingsRetry {
                // The price on screen when tapped, never one published after: a fee refused since is refused again.
                let shown = savingsRetry
                CustomButton(title: t("lightning__spark_exit__fund_savings"), variant: .secondary, isLoading: isPayingSavings) {
                    guard !isPayingSavings else { return }
                    isPayingSavings = true
                    defer { isPayingSavings = false }
                    if exit.isSavingsPaymentRefused {
                        do {
                            try await exit.retrySavingsPayment()
                        } catch {
                            app.toast(error)
                        }
                    } else if let shown {
                        do {
                            try await exit.paySavingsRefusal(satsPerVbyte: shown.rate, feeSats: shown.feeSats)
                        } catch let OnchainSendAttemptError.preDispatch(error) where error is SparkFundingChanged {
                            // Savings never pays more than the fee shown: progress shows the higher one to confirm.
                            app.toast(type: .info, title: t("lightning__spending_confirm__fees_changed_title"))
                        } catch {
                            app.toast(error)
                        }
                        await priceSavingsRetryOnce()
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
                    isConfirmingCancel = true
                }
                .padding(.bottom, 16)
                .accessibilityIdentifier("SparkExitCancel")
            }

            if record?.phase == .done {
                CustomButton(title: t("lightning__spark_exit__done_button")) {
                    navigation.reset()
                }
                .accessibilityIdentifier("SparkExitWalletOverview")
            } else {
                // Progress sits right above the screen it returns to: Spark, which a start opens it over, or the screen
                // that opened it directly, such as App Status.
                CustomButton(title: t(isFailedOrMissing ? "common__ok" : "lightning__setting_up_button")) {
                    navigation.navigateBack()
                }
                .accessibilityIdentifier("SparkExitProgressOk")
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .alert(t("lightning__spark_exit__cancel_title"), isPresented: $isConfirmingCancel) {
            Button(t("lightning__spark_exit__cancel"), role: .destructive) {
                Task {
                    // A funding address that cannot be read keeps the exit: a payment there is never orphaned.
                    switch await exit.cancel() {
                    case .keep: app.toast(type: .error, title: t("lightning__spark_exit__cancel_failed"), description: nil)
                    // Funding that reached the address is swept back on this screen, as the exit's leftover.
                    case .sweepFunding: break
                    case .forget: navigation.navigateBack()
                    case .notCancellable: break
                    }
                }
            }
            .accessibilityIdentifier("SparkExitCancelConfirm")

            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("lightning__spark_exit__cancel_text"))
        }
        .task {
            await SparkManager.shared.refreshState()
            await exit.tick()
        }
        .task(id: record?.hasUnseenResult) {
            exit.markResultSeen()
        }
        .task(id: savingsRefusal) {
            await priceSavingsRetry()
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
        SparkExitMath.canPayFeeBump(
            totalSats: option.totalSats,
            spendableSats: UInt64(max(0, wallet.spendableOnchainBalanceSats)),
            readsBitkitChain: SparkManager.shared.canFundFromChain
        )
    }

    /// Savings can't pay the selected rate, or, with none selected, any rate priced so far. Savings on a chain Spark
    /// does not read is off without a balance line, as on the start's funding screen.
    private var isInsufficient: Bool {
        guard SparkManager.shared.canFundFromChain else { return false }
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
                    DisplayText(t("lightning__spark_exit__fee_bump_title"), accentColor: .yellowAccent)

                    BodyMText(
                        t("lightning__spark_exit__fee_bump_text", variables: ["rate": "\(exit.record?.feeRateSatPerVbyte ?? 0)"]),
                        accentFont: Fonts.bold
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SparkExitLayout.headlineGap)
                    .padding(.bottom, 24)

                    if exit.isPricingFeeBump {
                        ProgressView()
                            .tint(.white32)
                            .frame(maxWidth: .infinity)
                    } else if exit.isFeeBumpLeavingLeaves {
                        BodyMText(t("lightning__spark_exit__fee_bump_leaves_behind"))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("SparkExitFeeBumpLeavesBehind")
                    } else if let error = exit.feeBumpError {
                        BodyMText(error)
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
                .padding(.bottom, 32)
            }

            if isInsufficient {
                CaptionText(t("lightning__spark_exit__fund_insufficient"))
                    .padding(.bottom, 16)
                    .accessibilityIdentifier("SparkExitFeeBumpInsufficient")
            }

            if exit.feeBumpError != nil {
                CustomButton(title: t("common__try_again")) {
                    await exit.loadFeeBumpOptions()
                    await priceSavingsPayments()
                    selectedRate = exit.feeBumpOptions.first(where: canPay)?.rate
                }
                .accessibilityIdentifier("SparkExitFeeBumpRetry")
            } else if !exit.isFeeBumpLeavingLeaves {
                CustomButton(
                    title: t(selected?.extraSats == 0 ? "lightning__spark_exit__fee_bump_confirm" : "lightning__spark_exit__fund_savings"),
                    isLoading: isPaying || exit.isPricingFeeBump
                ) {
                    await pay()
                }
                .disabled(selected.map { !canPay($0) } ?? true)
                .accessibilityIdentifier("SparkExitFeeBumpPay")
            }
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
        } catch let OnchainSendAttemptError.preDispatch(error) where error is SparkFundingChanged {
            // Savings never pays more than the fee confirmed: the rates are priced again for another confirm.
            app.toast(type: .info, title: t("lightning__spending_confirm__fees_changed_title"))
            exit.noteFeeBumpRefused(rate: selected.rate, preparedFeeSats: (error as? SparkFundingChanged)?.preparedFeeSats)
            await exit.loadFeeBumpOptions()
            await priceSavingsPayments()
            selectedRate = exit.feeBumpOptions.first(where: canPay)?.rate
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

/// The force transfer's steps: the emergency fees, publishing, the timelock and the sweep to savings.
struct SparkExitSteps: View {
    @Environment(\.openURL) private var openURL

    let record: SparkExitRecord

    private var transactions: [RecoveryTransaction] {
        record.recovery?.response.transactions ?? []
    }

    private var isFunded: Bool {
        if case .awaitingFunding = record.phase {
            return false
        }
        return true
    }

    /// The exit's own steps all landed: done, or only leaves the operators moved on-chain are left.
    private var isLanded: Bool {
        record.phase == .done || record.isRetryingFailedLeaves
    }

    private var fundingTxid: String? {
        record.funding.first?.txid ?? record.fundingPaymentTxid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkExitHeader(text: t("lightning__spark_exit__progress_overview"))
            step(t("lightning__spark_exit__step_funding"), isDone: isFunded, explorerTxid: fundingTxid)
            step(t("lightning__spark_exit__step_publish"), isDone: isLanded)
            step(t("lightning__spark_exit__step_timelock"), isDone: isLanded || SparkExitMath.areTimelocksMatured(transactions))
            step(t("lightning__spark_exit__step_sweep"), isDone: isLanded)
        }
    }

    private func step(_ title: String, isDone: Bool, explorerTxid: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(isDone ? "check-mark" : "clock")
                    .resizable()
                    .foregroundColor(isDone ? .yellowAccent : .textSecondary)
                    .frame(width: 16, height: 16)
                CaptionBText(title, textColor: .textPrimary)
                Spacer()
                if let explorerTxid {
                    CustomButton(
                        title: "",
                        size: .small,
                        icon: Image("git-branch").resizable().frame(width: 16, height: 16).foregroundColor(.yellowAccent)
                    ) {
                        if let url = URL(string: "\(Env.blockExplorerUrl)/tx/\(explorerTxid)") {
                            openURL(url)
                        }
                    }
                    .accessibilityLabel(t("wallet__activity_explore"))
                    .accessibilityIdentifier("SparkExitFundingExplore")
                }
            }
            .frame(height: 50)
            CustomDivider()
        }
    }
}

enum SparkExitLayout {
    /// The gap under an exit headline: master's 8, plus 1 so it renders like Android's, whose Display line height
    /// adds 9 dp under a headline. Measured on 2x media devices.
    static let headlineGap: CGFloat = 9
}
