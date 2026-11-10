import SwiftUI

struct SpendingConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(SparkTransferFlow.self) private var flow

    @State private var isPaying = false
    @State private var hideSwipeButton = false

    /// The coin drawing fills 72% of its square image, so this draws it about 134 pt wide, Android's third of the screen.
    private static let coinsSize: CGFloat = 186

    /// Fee rates move while the screen is open, so the quote is redone this often as well as on every change.
    private static let requoteInterval: Duration = .seconds(60)

    private struct QuoteInputs: Equatable {
        let amountSats: UInt64
        let isMaxAmount: Bool
        let speed: SparkTransferSpeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .disabled(isPaying)
                .padding(.bottom, 16)

            // The coins sit in the space left above the swipe, as on Android; on a short screen the content scrolls.
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        DisplayText(t("lightning__transfer__confirm"), accentColor: .purpleAccent)

                        SpendingConfirmFees(quote: flow.quote, speed: flow.speed, isLoading: flow.quote == nil && flow.quoteError == nil)
                            .padding(.top, 16)

                        if let error = flow.quoteError {
                            quoteError(error)
                                .padding(.bottom, 16)
                        }

                        SpendingSpeedPicker(quote: flow.quote, speed: Bindable(flow).speed)
                            .disabled(isPaying)
                            .padding(.top, 8)
                            .padding(.horizontal, -16)
                            .padding(.bottom, 10)

                        CustomButton(title: t("common__learn_more"), size: .small) {
                            navigation.navigate(.transferLearnMore)
                        }
                        .disabled(isPaying)
                        .accessibilityIdentifier("SpendingConfirmMore")

                        Spacer(minLength: 0)

                        Image("coin-stack-x")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: Self.coinsSize, height: Self.coinsSize)
                            .frame(maxWidth: .infinity)

                        Spacer(minLength: 0)
                    }
                    // The speed rows run edge to edge, so the scroll spans the screen and pads its own content.
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(minHeight: geo.size.height)
                }
            }
            .padding(.horizontal, -16)

            if !hideSwipeButton {
                SwipeButton(
                    title: t("lightning__transfer__swipe"),
                    accentColor: .purpleAccent,
                    isLoading: isPaying
                ) {
                    try await onConfirm()
                }
                .disabled(!canConfirm)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SpendingConfirm")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .onAppear { SparkFundingRecovery.confirmScreenOpen = true }
        .onDisappear { SparkFundingRecovery.confirmScreenOpen = false }
        .onReceive(OnchainSendAttemptService.localResolutionPublisher.receive(on: DispatchQueue.main)) { resolution in
            guard Self.followsRecovered(resolution, isPaying: isPaying), !hideSwipeButton else { return }
            // This screen owns the recovered funding: follow it at the chosen speed, as a swipe would have.
            flow.onRecoveredBroadcast(txid: resolution.txid, attemptId: resolution.attemptId)
            hideSwipeButton = true
            navigation.navigate(.settingUp)
        }
        .task(id: QuoteInputs(amountSats: flow.amountSats, isMaxAmount: flow.isMaxAmount, speed: flow.speed)) {
            guard !SparkTransferFlow.isRunningInPreview else { return }
            while !Task.isCancelled {
                if !isPaying {
                    await flow.refreshQuote(wallet: wallet, feeEstimatesManager: feeEstimatesManager)
                }
                try? await Task.sleep(for: Self.requoteInterval)
            }
        }
    }

    private var canConfirm: Bool {
        guard let quote = flow.quote, !isPaying, !flow.isQuoting else { return false }
        return quote.networkFeeSats > 0 && quote.toSpendingSats(for: flow.speed) > 0
    }

    private func quoteError(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            BodyMText(message, textColor: .redAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
            CustomButton(title: t("common__retry"), size: .small, isLoading: flow.isQuoting) {
                await flow.refreshQuote(wallet: wallet, feeEstimatesManager: feeEstimatesManager)
            }
            .fixedSize()
            .accessibilityIdentifier("SpendingConfirmRetry")
        }
    }

    private func onConfirm() async throws {
        guard let shown = flow.quote, !isPaying else { return }
        isPaying = true
        defer { isPaying = false }

        guard let fresh = await flow.refreshQuote(wallet: wallet, feeEstimatesManager: feeEstimatesManager) else {
            throw AppError(message: t("lightning__spending_confirm__error_quote"), debugMessage: "Re-quote before sending failed")
        }
        guard fresh.coversClaimFee else {
            app.toastBelowClaimFee(fresh)
            throw SpendingFeesIncreasedError()
        }
        let increase = fresh.increase(over: shown, speed: flow.speed)
        if increase > 0 {
            app.toast(
                type: .info,
                title: t("lightning__spending_confirm__fees_changed_title"),
                description: t(
                    "lightning__spending_confirm__fees_changed_network",
                    variables: ["amount": currency.primaryAmountText(sats: increase)]
                )
            )
            throw SpendingFeesIncreasedError()
        }

        flow.approveSwipe()
        do {
            let txid = try await transfer.fundSpark(
                address: fresh.address,
                amountSats: fresh.depositSats,
                satsPerVbyte: fresh.satsPerVbyte,
                txFee: fresh.networkFeeSats,
                isMaxAmount: flow.isMaxAmount
            )
            flow.onBroadcast(txid: txid)
            await wallet.updateBalanceState()
            navigation.navigate(.settingUp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                hideSwipeButton = true
            }
        } catch let OnchainSendAttemptError.preDispatch(error) where error is SparkFundingChanged {
            // The max quote reads the cached savings balance, so it is read again before pricing the new transfer.
            await wallet.syncStateAsync()
            // The next swipe approves the fee this one was refused for.
            flow.onFundingChanged(preparedFeeSats: (error as? SparkFundingChanged)?.preparedFeeSats)
            guard let repriced = await flow.refreshQuote(wallet: wallet, feeEstimatesManager: feeEstimatesManager) else {
                throw AppError(message: t("lightning__spending_confirm__error_quote"), debugMessage: "Re-quote after refusal failed")
            }
            let toSpendingSats = repriced.toSpendingSats(for: flow.speed)
            if flow.isMaxAmount, toSpendingSats != fresh.toSpendingSats(for: flow.speed) {
                // A max transfer's amount moves with the balance and fees, so a fee increase would mostly be that move.
                app.toast(
                    type: .info,
                    title: t("lightning__spending_confirm__max_changed_title"),
                    description: t(
                        "lightning__spending_confirm__max_changed",
                        variables: ["amount": currency.primaryAmountText(sats: toSpendingSats)]
                    )
                )
            } else {
                app.toast(
                    type: .info,
                    title: t("lightning__spending_confirm__fees_changed_title"),
                    description: t(
                        "lightning__spending_confirm__fees_changed_network",
                        variables: ["amount": currency.primaryAmountText(sats: repriced.increase(over: fresh, speed: flow.speed))]
                    )
                )
            }
            throw SpendingFeesIncreasedError()
        } catch {
            if let attemptId = await OnchainSendAttemptService.shared.unresolvedSparkFundingAttemptId() {
                flow.bindApproval(to: attemptId, after: error)
            }
            Logger.error("Failed to transfer to spending: \(error)", context: "SpendingConfirm")
            app.toast(
                type: .error,
                title: t("wallet__send_error_tx_failed"),
                description: AppError(error: error).message
            )
            throw error
        }
    }
}

extension SpendingConfirm {
    /// A Spark funding that resolved on its own while this screen stayed open, after an unknown outcome the user left
    /// pending, would let the swipe send the transfer again; the swipe's own funding resolves while it is paying.
    static func followsRecovered(_ resolution: OnchainSendLocalResolution, isPaying: Bool) -> Bool {
        resolution.isSparkFunding && !isPaying
    }
}

/// The swipe reset after the fees went up while the screen was open; the toast says by how much.
struct SpendingFeesIncreasedError: Error {}

/// Network fee, spending fee, what reaches spending and what leaves savings, in the confirm screen's grid.
struct SpendingConfirmFees: View {
    let quote: SparkTransferQuote?
    let speed: SparkTransferSpeed
    var isLoading = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__network_fee"),
                    amount: quote?.networkFeeSats ?? 0,
                    isLoading: isLoading
                )
                .frame(maxWidth: .infinity)

                FeeDisplayRow(
                    label: t("lightning__spending_confirm__spending_fee"),
                    amount: quote?.claimFeeSats(for: speed) ?? 0,
                    prefix: SpendingSpeedPicker.feePrefix(for: speed),
                    isLoading: isLoading
                )
                .frame(maxWidth: .infinity)
            }

            HStack {
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__amount"),
                    amount: quote?.toSpendingSats(for: speed) ?? 0,
                    // What reaches spending is net of the estimated claim fee, so it is an estimate too.
                    prefix: SpendingSpeedPicker.feePrefix(for: speed),
                    isLoading: isLoading
                )
                .frame(maxWidth: .infinity)

                FeeDisplayRow(
                    label: t("lightning__spending_confirm__total"),
                    amount: quote?.totalSats ?? 0,
                    isLoading: isLoading
                )
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SpendingConfirmFees")
    }
}

/// Instant or Later, in the style of the send flow's fee-speed rows.
struct SpendingSpeedPicker: View {
    let quote: SparkTransferQuote?
    @Binding var speed: SparkTransferSpeed

    /// Both claim fees are estimates: Instant's is its ceiling, Later's the current rate.
    static func feePrefix(for _: SparkTransferSpeed) -> String {
        "±"
    }

    var body: some View {
        VStack(spacing: 0) {
            FeeItem(
                title: t("fee__instant__title"),
                subtitle: t("lightning__spending_confirm__instant_text"),
                iconName: TransactionSpeed.fast.iconName,
                iconColor: .purpleAccent,
                amount: quote?.claimFees.instantMaxSats ?? 0,
                amountPrefix: Self.feePrefix(for: .instant),
                isSelected: speed == .instant,
                isDisabled: false,
                dividerAtBottom: true
            ) {
                speed = .instant
            }
            .accessibilityIdentifier("SpendingConfirmInstant")

            FeeItem(
                title: t("lightning__spending_confirm__later"),
                subtitle: t("lightning__spending_confirm__later_text"),
                iconName: TransactionSpeed.normal.iconName,
                iconColor: .purpleAccent,
                amount: quote?.claimFees.laterSats ?? 0,
                amountPrefix: Self.feePrefix(for: .later),
                isSelected: speed == .later,
                isDisabled: false,
                dividerAtBottom: true
            ) {
                speed = .later
            }
            .accessibilityIdentifier("SpendingConfirmLater")
        }
    }
}

private extension SparkTransferQuote {
    static let preview = SparkTransferQuote(
        address: "bcrt1qpreview",
        satsPerVbyte: 6,
        networkFeeSats: 577,
        depositSats: 100_000,
        claimFees: SparkClaimFees(instantMaxSats: 1093, laterSats: 198)
    )
}

#Preview("Instant") {
    spendingConfirmPreview(SparkTransferFlow(amountSats: 100_000, speed: .instant, quote: .preview))
}

#Preview("Later") {
    spendingConfirmPreview(SparkTransferFlow(amountSats: 100_000, speed: .later, quote: .preview))
}

#Preview("Loading") {
    spendingConfirmPreview(SparkTransferFlow(amountSats: 100_000))
}

@MainActor
private func spendingConfirmPreview(_ flow: SparkTransferFlow) -> some View {
    NavigationStack {
        SpendingConfirm()
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(FeeEstimatesManager())
            .environmentObject(NavigationViewModel())
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(TransferViewModel())
            .environmentObject(WalletViewModel())
            .environment(flow)
    }
    .preferredColorScheme(.dark)
}
