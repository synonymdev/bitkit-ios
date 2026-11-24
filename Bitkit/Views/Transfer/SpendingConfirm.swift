import SwiftUI

struct SpendingConfirm: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(SparkTransferFlow.self) private var flow

    @State private var isPaying = false
    @State private var hideSwipeButton = false

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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    DisplayText(t("lightning__transfer__confirm"), accentColor: .purpleAccent)

                    SpendingConfirmFees(quote: flow.quote, speed: flow.speed, isLoading: flow.quote == nil && flow.quoteError == nil)

                    if let error = flow.quoteError {
                        quoteError(error)
                    }

                    SpendingSpeedPicker(
                        quote: flow.quote,
                        speed: Bindable(flow).speed,
                        isLoading: flow.quote == nil && flow.quoteError == nil
                    )
                    .disabled(isPaying)

                    CustomButton(title: t("common__learn_more"), size: .small) {
                        navigation.navigate(.transferLearnMore)
                    }
                    .disabled(isPaying)
                    .accessibilityIdentifier("SpendingConfirmMore")
                }
                .padding(.bottom, 16)
            }

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
            // This screen owns the recovered funding: follow it at the chosen speed, as a swipe would have, unless the
            // flow already follows it.
            if flow.txid != resolution.txid {
                flow.onRecoveredBroadcast(txid: resolution.txid, attemptId: resolution.attemptId)
            }
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
        // A funding of this transfer resolved while another screen showed, so it is followed, not sent again.
        if flow.txid != nil {
            navigation.navigate(.settingUp)
            return
        }
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
        } catch let unresolved as SparkFundingUnresolved {
            // The funding may be on the network and is kept, so Payment Pending shows it, as for any on-chain send.
            if let attemptId = await OnchainSendAttemptService.shared.unresolvedSparkFundingAttemptId() {
                flow.bindApproval(to: attemptId)
            }
            Logger.warn("Spark funding \(unresolved.txid) is unresolved", context: "SpendingConfirm")
            if let reason = unresolved.rejectionReason {
                app.toast(type: .error, title: t("wallet__onchain_broadcast_rejected"),
                          description: t("wallet__onchain_broadcast_rejected_note", variables: ["reason": reason]))
            } else {
                app.toast(type: .warning, title: t("wallet__onchain_broadcast_unconfirmed"),
                          description: t("wallet__onchain_broadcast_unconfirmed_note"))
            }
            let route = await SendConfirmationView.onchainPendingRoute(txid: unresolved.txid, requestId: nil)
            sheets.showSheet(.send, data: SendConfig(view: route))
            throw unresolved
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

/// Network fee, service fee, what reaches spending and what leaves savings, in the confirm screen's grid; a tap switches
/// every amount on the screen between bitcoin and the local currency.
struct SpendingConfirmFees: View {
    let quote: SparkTransferQuote?
    let speed: SparkTransferSpeed
    var isLoading = false
    /// The Spark deposit address a hardware wallet asks to confirm on the device.
    var address: String?
    /// 24 as the Review frame draws it; the hardware wallet's Review & Sign frame draws 10.
    var rowSpacing: CGFloat = 24

    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack {
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__network_fee"),
                    amount: quote?.networkFeeSats ?? 0,
                    isLoading: isLoading
                )
                .frame(maxWidth: .infinity)
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__lsp_fee"),
                    amount: quote?.claimFeeSats(for: speed) ?? 0,
                    isLoading: isLoading
                )
                .frame(maxWidth: .infinity)
            }

            HStack {
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__amount"),
                    amount: quote?.toSpendingSats(for: speed) ?? 0,
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

            if let address {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("lightning__transfer_hw__address"))
                    BodySSBText(address)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.bottom, 8)
                    Divider()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("SpendingConfirmAddress")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard Self.togglesDisplay(from: currency.primaryDisplay, hasRate: currency.hasUsableRate) else { return }
            withAnimation { currency.togglePrimaryDisplay() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SpendingConfirmFees")
    }

    /// Without a positive rate for the local currency every amount would read zero in it, so the tap stays in bitcoin.
    nonisolated static func togglesDisplay(from display: PrimaryDisplay, hasRate: Bool) -> Bool {
        display == .fiat || hasRate
    }
}

/// Fast or Normal, each with its claim fee: Fast's is its ceiling ("max"), Normal's the current rate ("est").
struct SpendingSpeedPicker: View {
    let quote: SparkTransferQuote?
    @Binding var speed: SparkTransferSpeed
    /// Shimmers the fees while the quote is loading; stops once it fails, so the rows don't look stuck.
    var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            SpendingSpeedRow(
                title: t("fee__fast__title"),
                subtitle: t("lightning__spending_confirm__instant_text"),
                iconName: TransactionSpeed.fast.iconName,
                amount: quote?.claimFees.instantMaxSats,
                amountCaption: t("lightning__spending_confirm__fee_max"),
                isLoading: isLoading,
                isSelected: speed == .instant
            ) {
                speed = .instant
            }
            .accessibilityIdentifier("SpendingConfirmInstant")

            Divider()

            SpendingSpeedRow(
                title: t("fee__normal__title"),
                subtitle: t("lightning__spending_confirm__later_text"),
                iconName: "clock",
                amount: quote?.claimFees.laterSats,
                amountCaption: t("lightning__spending_confirm__fee_est"),
                isLoading: isLoading,
                isSelected: speed == .later
            ) {
                speed = .later
            }
            .accessibilityIdentifier("SpendingConfirmLater")
        }
    }
}

private struct SpendingSpeedRow: View {
    let title: String
    let subtitle: String
    let iconName: String
    let amount: UInt64?
    let amountCaption: String
    let isLoading: Bool
    let isSelected: Bool
    let onPress: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: 12) {
                HStack(spacing: 16) {
                    Image(iconName)
                        .resizable()
                        .foregroundColor(isEnabled ? .purpleAccent : .gray)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 0) {
                        BodyMSBText(title)
                        BodySSBText(subtitle, textColor: .textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isLoading || amount != nil {
                    VStack(alignment: .trailing, spacing: 0) {
                        MoneyText(sats: Int(amount ?? 0), size: .bodyMSB, symbol: true, fillsWidth: false, shimmer: isLoading)
                        BodySSBText(amountCaption, textColor: .textSecondary)
                    }
                    .fixedSize()
                }

                Image("check-mark")
                    .resizable()
                    .foregroundColor(.purpleAccent)
                    .frame(width: 22, height: 22)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            .environmentObject(SheetViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(WalletViewModel())
            .environment(flow)
    }
    .preferredColorScheme(.dark)
}
