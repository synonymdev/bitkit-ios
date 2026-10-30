import SwiftUI

/// Transfer to Spending through Arkade: savings go to the wallet's Arkade boarding address. Once it confirms, the Arkade
/// wallet boards it into the operator's next batch by itself, with no fee.
struct ArkadeFundingAmountView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var amountViewModel = AmountInputViewModel()
    @State private var fastMaxSats: UInt64?

    private var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    /// The balance less a fast-rate fee for sending all of it to the deposit address, the rate the transfer pays.
    private var maxSats: UInt64 {
        fastMaxSats ?? UInt64(max(0, wallet.spendableOnchainBalanceSats))
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
                    navigation.navigate(.arkadeFundingConfirm(amountSats: amountSats, isMaxAmount: amountSats >= maxSats))
                }
                .accessibilityIdentifier("SpendingAmountContinue")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SpendingAmount")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task(id: wallet.spendableOnchainBalanceSats) { await loadFastMax() }
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

    private func loadFastMax() async {
        do {
            let address = try await ArkadeManager.shared.depositAddress()
            guard let feeRates = await feeEstimatesManager.getEstimates(refresh: false) else { return }
            let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
            fastMaxSats = try await wallet.calculateMaxSendableAmount(address: address, satsPerVByte: rate)
        } catch {
            Logger.warn("Failed to estimate the most Arkade funding can send: \(error)", context: "ArkadeFundingAmountView")
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

struct ArkadeFundingConfirmView: View {
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
                    FeeDisplayRow(label: t("lightning__arkade_claim_fee"), amount: claimFeeSats)
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
                    let txid = try await transfer.fundArkade(
                        address: address,
                        amountSats: isMaxAmount ? amountSats : depositSats,
                        satsPerVbyte: feeRate,
                        txFee: networkFeeSats,
                        isMaxAmount: isMaxAmount
                    )
                    await wallet.updateBalanceState()
                    navigation.navigate(.arkadeFundingDeposit(txid: txid))
                } catch {
                    Logger.error("Failed to fund Arkade: \(error)", context: "ArkadeFundingConfirmView")
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
            let address = try await ArkadeManager.shared.depositAddress()
            guard let feeRates = await feeEstimatesManager.getEstimates(refresh: true) else { return }
            let rate = TransactionSpeed.fast.getFeeRate(from: feeRates)
            networkFeeSats = if isMaxAmount {
                try await wallet.estimateSendAllFee(address: address, satsPerVByte: rate)
            } else {
                try await wallet.calculateTotalFee(address: address, amountSats: amountSats, satsPerVByte: rate)
            }
            claimFeeSats = ArkadeManager.shared.boardingFeeSats()
            feeRate = rate
            self.address = address
        } catch {
            Logger.error("Failed to price Arkade funding: \(error)", context: "ArkadeFundingConfirmView")
            app.toast(error)
        }
    }
}

struct ArkadeFundingDepositView: View {
    @EnvironmentObject var navigation: NavigationViewModel

    let txid: String

    private let arkade = ArkadeManager.shared
    /// How often to check the deposit until it is boarded; boarding needs 1 confirmation, then a batch.
    private static let pollInterval: Duration = .seconds(15)

    private var stage: ArkadeDepositStage {
        ArkadeDepositStage(deposit: arkade.deposits.first { $0.txid.caseInsensitiveCompare(txid) == .orderedSame })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"), showBackButton: false)
                .padding(.bottom, 16)

            DisplayText(t("lightning__savings_progress__title"), accentColor: .purpleAccent)
                .padding(.bottom, 8)

            BodyMText(t(stage.textKey))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("hourglass")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)

            CustomButton(title: t("common__continue"), variant: .secondary) {
                navigation.reset()
            }
            .accessibilityIdentifier("ArkadeDepositContinue")
            .padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ArkadeDeposit")
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .task { await watchDeposit() }
    }

    private func watchDeposit() async {
        while !Task.isCancelled, stage != .boarded {
            await arkade.refreshState()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

/// Where a deposit into Arkade stands: broadcast, then confirmed and waiting for the next batch, then boarded.
enum ArkadeDepositStage: Equatable {
    /// Broadcast and waiting for its first confirmation.
    case looking
    /// Confirmed; the wallet boards it in the operator's next batch.
    case boarding
    /// In the Arkade balance.
    case boarded

    init(deposit: ArkadeDeposit?) {
        if deposit?.isClaimed == true {
            self = .boarded
        } else if (deposit?.confirmations ?? 0) > 0 {
            self = .boarding
        } else {
            self = .looking
        }
    }

    var textKey: String {
        switch self {
        case .looking: "lightning__arkade_deposit__looking"
        case .boarding: "lightning__arkade_deposit__boarding"
        case .boarded: "lightning__arkade_deposit__boarded"
        }
    }
}
