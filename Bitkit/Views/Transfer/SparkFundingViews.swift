import SwiftUI

/// Transfer to Spending through Spark: savings go to the Spark deposit address, then the deposit screen offers the
/// early claim the provider quotes for that deposit, since its fee is only known once the deposit exists.
struct SparkFundingAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var amountViewModel = AmountInputViewModel()

    private var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var maxSats: UInt64 {
        UInt64(max(0, wallet.spendableOnchainBalanceSats))
    }

    private var isValidAmount: Bool {
        amountSats > 0 && amountSats <= maxSats
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(t("lightning__spending_amount__title"), accentColor: .purpleAccent)
                    .fixedSize(horizontal: false, vertical: true)

                NumberPadTextField(
                    viewModel: amountViewModel,
                    showConversion: false,
                    testIdentifier: "SpendingAmountNumberField"
                )
                .onTapGesture {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
                .padding(.vertical, 32)

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(
                        label: t("wallet__send_available"),
                        amount: Int(maxSats),
                        testIdentifier: "SpendingAmountAvailable"
                    )
                    .onTapGesture {
                        amountViewModel.updateFromSats(maxSats, currency: currency)
                    }

                    Spacer()

                    numberPadButtons
                }
                .padding(.bottom, 12)

                Divider()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(title: t("common__continue"), isDisabled: !isValidAmount) {
                    navigation.navigate(.sparkFundingConfirm(amountSats: amountSats, isMaxAmount: amountSats >= maxSats))
                }
                .accessibilityIdentifier("SpendingAmountContinue")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SpendingAmount")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onChange(of: maxSats, initial: true) {
            amountViewModel.maxAmountOverride = maxSats > 0 ? maxSats : nil
        }
        .onChange(of: amountViewModel.maxExceededCount) {
            app.toast(
                type: .warning,
                title: t("lightning__spending_amount__error_max__title"),
                description: t(
                    "lightning__spending_amount__error_max__description",
                    variables: ["amount": CurrencyFormatter.formatSats(maxSats)]
                ),
                visibilityTime: Toast.visibilityTimeShort
            )
        }
    }

    private var numberPadButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "arrow-up-down"
            ) {
                withAnimation {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
            }

            NumberPadActionButton(text: t("lightning__spending_amount__quarter")) {
                amountViewModel.updateFromSats(maxSats / 4, currency: currency)
            }
            .accessibilityIdentifier("SpendingAmountQuarter")

            NumberPadActionButton(text: t("common__max")) {
                amountViewModel.updateFromSats(maxSats, currency: currency)
            }
            .accessibilityIdentifier("SpendingAmountMax")
        }
    }
}

struct SparkFundingConfirmView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let amountSats: UInt64
    let isMaxAmount: Bool

    @State private var address: String?
    @State private var feeRate: UInt32 = 0
    @State private var networkFeeSats: UInt64 = 0
    @State private var claimFeeSats: UInt64 = 0

    /// What leaves savings for the deposit: a max transfer sends the balance less the network fee.
    private var depositSats: UInt64 {
        isMaxAmount ? amountSats - min(amountSats, networkFeeSats) : amountSats
    }

    private var isPriced: Bool {
        address != nil && networkFeeSats > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__transfer__confirm"), accentColor: .purpleAccent)

            VStack(spacing: 16) {
                HStack {
                    FeeDisplayRow(label: t("lightning__spending_confirm__network_fee"), amount: networkFeeSats)
                        .frame(maxWidth: .infinity)
                    FeeDisplayRow(label: t("lightning__spark_claim_fee"), amount: claimFeeSats)
                        .frame(maxWidth: .infinity)
                }
                HStack {
                    FeeDisplayRow(label: t("lightning__spending_confirm__amount"), amount: depositSats - min(depositSats, claimFeeSats))
                        .frame(maxWidth: .infinity)
                    FeeDisplayRow(label: t("lightning__spending_confirm__total"), amount: depositSats + networkFeeSats)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 16)

            Spacer()

            SwipeButton(title: t("lightning__transfer__swipe"), accentColor: .purpleAccent, isDisabled: !isPriced) {
                guard let address else { return }
                do {
                    let txid = try await transfer.fundSpark(
                        address: address,
                        amountSats: isMaxAmount ? amountSats : depositSats,
                        satsPerVbyte: feeRate,
                        txFee: networkFeeSats,
                        isMaxAmount: isMaxAmount
                    )
                    await wallet.updateBalanceState()
                    navigation.navigate(.sparkFundingDeposit(txid: txid))
                } catch {
                    Logger.error("Failed to fund Spark: \(error)", context: "SparkFundingConfirmView")
                    app.toast(error)
                    throw error
                }
            }
        }
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .task { await price() }
    }

    private func price() async {
        do {
            let address = try await SparkManager.shared.depositAddress()
            guard let feeRates = await feeEstimatesManager.getEstimates(refresh: true) else { return }
            let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
            networkFeeSats = if isMaxAmount {
                try await wallet.estimateSendAllFee(address: address, satsPerVByte: rate)
            } else {
                try await wallet.calculateTotalFee(address: address, amountSats: amountSats, satsPerVByte: rate)
            }
            claimFeeSats = try await SparkManager.shared.estimateDepositClaimFeeSats(amountSats: depositSats)
            feeRate = rate
            self.address = address
        } catch {
            Logger.error("Failed to price Spark funding: \(error)", context: "SparkFundingConfirmView")
            app.toast(error)
        }
    }
}

struct SparkFundingDepositView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    let txid: String

    @State private var offer: SparkClaimOffer?
    @State private var claim: SparkEarlyClaim?
    @State private var isClaiming = false

    /// Looks for the deposit for 5 minutes, after which Spark still claims it on its own.
    private static let pollAttempts = 60
    private static let pollInterval: Duration = .seconds(5)
    /// Roughly how long a block takes, to turn confirmations into minutes.
    private static let minutesPerConfirmation: UInt32 = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"), showBackButton: false)
                .padding(.bottom, 16)

            DisplayText(t("lightning__savings_progress__title"), accentColor: .purpleAccent)
                .padding(.bottom, 8)

            content

            Spacer()

            Image("hourglass")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)

            CustomButton(title: t(isChoice ? "lightning__spark_deposit__wait_button" : "common__continue"), variant: .secondary) {
                navigation.reset()
            }
            .disabled(isClaiming)
            .accessibilityIdentifier("SparkDepositContinue")
            .padding(.bottom, 16)
        }
        .accessibilityIdentifier("SparkDeposit")
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .task { await watchDeposit() }
    }

    private var isChoice: Bool {
        guard claim == nil, case .choice = offer?.kind else { return false }
        return true
    }

    @ViewBuilder
    private var content: some View {
        if let offer {
            switch (offer.kind, claim) {
            case let (.standard(feeSats, confirmations), _):
                text(standardText(confirmations))
                fees([(t("lightning__spark_claim_fee"), feeSats)])
            case let (.automatic(feeSats, confirmations), _):
                text(t("lightning__spark_deposit__waiting", variables: ["when": whenText(confirmations)]))
                fees([(t("lightning__spark_claim_fee"), feeSats)])
            case let (.choice(earlyFee, _, _, _), .claimed):
                text(t("lightning__spark_deposit__claimed"))
                fees([(t("lightning__spark_claim_fee"), earlyFee)])
            case let (.choice(earlyFee, _, _, _), .waiting):
                text(t("lightning__spark_deposit__waiting_next"))
                fees([(t("lightning__spark_claim_fee"), earlyFee)])
            case let (.choice(_, _, standardFee, standardConfirmations), .declined):
                text(standardText(standardConfirmations))
                fees([(t("lightning__spark_claim_fee"), standardFee)])
            case let (.choice(earlyFee, earlyConfirmations, standardFee, standardConfirmations), _):
                let early = whenText(earlyConfirmations)
                text(t("lightning__spark_deposit__choice", variables: [
                    "when": early,
                    "standard": "\(standardConfirmations)",
                    "minutes": "\(standardConfirmations * Self.minutesPerConfirmation)",
                ]))
                fees([
                    (t("lightning__spark_deposit__early_fee", variables: ["when": early]), earlyFee),
                    (t("lightning__spark_deposit__standard_fee"), standardFee),
                ])
                CustomButton(title: t("lightning__spark_deposit__claim_early", variables: ["when": early]), isLoading: isClaiming) {
                    await claimEarly(offer)
                }
                .accessibilityIdentifier("SparkDepositClaimEarly")
                .padding(.top, 24)
            }
        } else {
            text(t("lightning__spark_deposit__looking"))
        }
    }

    private func text(_ value: String) -> some View {
        BodyMText(value)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fees(_ rows: [(String, UInt64)]) -> some View {
        HStack {
            ForEach(rows, id: \.0) { row in
                FeeDisplayRow(label: row.0, amount: row.1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 16)
    }

    private func standardText(_ confirmations: UInt32) -> String {
        t("lightning__spark_deposit__standard", variables: [
            "standard": "\(confirmations)",
            "minutes": "\(confirmations * Self.minutesPerConfirmation)",
        ])
    }

    private func whenText(_ confirmations: UInt32) -> String {
        switch confirmations {
        case 0: t("lightning__spark_deposit__now")
        case 1: t("lightning__spark_deposit__later_one")
        default: t("lightning__spark_deposit__later", variables: ["count": "\(confirmations)"])
        }
    }

    private func watchDeposit() async {
        guard offer == nil else { return }
        for _ in 0 ..< Self.pollAttempts {
            do {
                if let found = try await SparkManager.shared.depositClaimOffer(txid: txid) {
                    offer = found
                    return
                }
            } catch {
                Logger.warn("Failed to quote Spark deposit \(txid): \(error)", context: "SparkFundingDepositView")
            }
            await SparkManager.shared.refreshState()
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled {
                return
            }
        }
        Logger.warn("Spark did not list deposit \(txid) in time", context: "SparkFundingDepositView")
    }

    private func claimEarly(_ offer: SparkClaimOffer) async {
        guard !isClaiming else { return }
        isClaiming = true
        defer { isClaiming = false }
        do {
            let result = try await SparkManager.shared.claimEarly(offer)
            if case let .repriced(requiredFeeSats) = result, case let .choice(_, confirmations, standardFee, standardConfirmations) = offer.kind {
                self.offer?.kind = .choice(
                    earlyFeeSats: requiredFeeSats,
                    earlyConfirmations: confirmations,
                    standardFeeSats: standardFee,
                    standardConfirmations: standardConfirmations
                )
            } else {
                claim = result
            }
        } catch {
            Logger.error("Failed to claim Spark deposit \(offer.txid) early: \(error)", context: "SparkFundingDepositView")
            app.toast(error)
        }
    }
}
