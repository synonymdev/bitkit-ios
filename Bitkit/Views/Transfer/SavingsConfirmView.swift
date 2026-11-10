import LDKNode
import SwiftUI

struct SavingsConfirmView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var hideSwipeButton = false

    private var readyChannels: [ChannelDetails] {
        wallet.channels?.filter(\.isChannelReady) ?? []
    }

    private var sparkSats: UInt64 {
        SparkManager.shared.balanceSats
    }

    /// Each ready channel and a Spark balance is a row of the Advanced list.
    private var hasMultipleItems: Bool {
        readyChannels.count + (sparkSats > 0 ? 1 : 0) > 1
    }

    private var hasSelectedItems: Bool {
        transfer.selectedChannelIds != nil || !transfer.isSparkSelected
    }

    private var selection: SavingsSelection {
        transfer.savingsSelection(readyChannelIds: readyChannels.map(\.channelId), sparkSats: sparkSats)
    }

    /// Spark is priced while picked with a balance, also once too small to move, so a receive can bring it back in.
    private var pricesSpark: Bool {
        transfer.isSparkSelected && sparkSats > 0
    }

    private var channels: [ChannelDetails] {
        let ids = selection.channelIds
        return readyChannels.filter { ids.contains($0.channelId) }
    }

    private var totalSats: UInt64 {
        channels.reduce(0) { $0 + $1.balanceOnCloseSats }
    }

    /// What the selected channels can send, so a swap never falls back to paying from Spark.
    private var channelsSendableSats: UInt64 {
        channels.filter(\.isUsable).reduce(0) { $0 + $1.nextOutboundHtlcLimitMsat } / 1000
    }

    private var swapState: SavingsSwapState {
        transfer.savingsSwapState
    }

    private var headlineSats: UInt64 {
        (swapState.quote?.amountSat ?? totalSats) + (selection.withdrawsSpark ? sparkSats : 0)
    }

    /// What reaches savings: the swap's receive plus Spark's balance net of its withdrawal fee.
    private func receiveSats(_ quote: SavingsSwapQuote) -> UInt64 {
        guard selection.withdrawsSpark else { return quote.receiveSat }
        let feeSats = transfer.sparkWithdrawFeeSats ?? 0
        return quote.receiveSat + (sparkSats > feeSats ? sparkSats - feeSats : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            // The piggybank keeps its size; when the fees, slider and Spark row make the content tall, it scrolls above the swipe.
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        DisplayText(t("lightning__transfer__confirm"), accentColor: .brandAccent)
                            .fixedSize(horizontal: false, vertical: true)

                        CaptionMText(t("lightning__savings_confirm__label"))
                            .padding(.top, 32)
                            .padding(.bottom, 16)

                        MoneyText(sats: Int(headlineSats), size: .display, symbol: true)

                        if let quote = swapState.quote {
                            quoteSection(quote)
                        }

                        sparkSection

                        if hasMultipleItems {
                            HStack(spacing: 16) {
                                if hasSelectedItems {
                                    CustomButton(title: t("lightning__savings_confirm__transfer_all"), size: .small) {
                                        transfer.selectAllForSavings()
                                    }
                                } else {
                                    CustomButton(title: t("common__advanced"), size: .small) {
                                        navigation.navigate(.savingsAdvanced)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 32)
                        }

                        Spacer(minLength: 0)

                        // A spinner stands in for the piggybank while the quote loads.
                        Group {
                            if swapState.quote == nil, swapState.isLoading {
                                ProgressView()
                            } else {
                                Image("piggybank-right")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 256, height: 256)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: geo.size.height)
                }
            }

            if !hideSwipeButton {
                SwipeButton(
                    title: t("lightning__transfer__swipe"),
                    accentColor: .brandAccent,
                    isLoading: (swapState.quote == nil && swapState.isLoading) || transfer.isPricingSparkWithdrawal
                ) {
                    // The swipe always commits the transfer: it swaps when a quote is ready and
                    // otherwise falls back to the pre-swap behaviour of closing the channel, so it
                    // is never inert.
                    try await confirmSwipe()
                    do {
                        try await Task.sleep(nanoseconds: 300_000_000)

                        navigation.navigate(.savingsProgress)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            hideSwipeButton = true
                        }
                    } catch {
                        app.toast(error)
                        throw error
                    }
                }
                .disabled(selection.isEmpty || !transfer.isSparkWithdrawalPriced(withdrawsSpark: selection.withdrawsSpark))
            }

            if swapState.quote != nil {
                // Fallback: drain a whole channel on-chain by closing it instead of swapping.
                CustomButton(
                    title: t("lightning__savings_confirm__close_instead"),
                    variant: .tertiary,
                    isDisabled: !transfer.isSparkWithdrawalPriced(withdrawsSpark: selection.withdrawsSpark) || transfer.isRecheckingSparkFee
                ) {
                    guard transfer.onTransferToSavingsConfirm(channels: channels, withdrawsSpark: selection.withdrawsSpark, mode: .close) else {
                        return
                    }
                    navigation.navigate(.savingsProgress)
                }
                .padding(.top, 12)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .task(id: totalSats) {
            // Pull the latest node balances so a just-received payment is reflected, then
            // present the swap fee before the user commits. Recomputed when the amount changes.
            // The quote reads as loading across the sync too, so the swipe cannot land in the
            // channel-close fallback while a quote is still on its way.
            transfer.beginSavingsSwapQuoteLoad()
            await wallet.syncStateAsync()
            await transfer.loadSavingsSwapQuote(
                requestedSat: totalSats,
                spendableSats: channelsSendableSats
            )
        }
        .onChange(of: pricesSpark ? sparkSats : nil, initial: true) { _, balanceSats in
            guard let balanceSats else { return }
            transfer.loadSparkWithdrawFee(balanceSats: balanceSats, savingsAddress: wallet.onchainAddress)
        }
    }

    /// Spark's withdrawal fee, or why it could not be priced, below the swap's fees or the headline when there is no swap.
    @ViewBuilder
    private var sparkSection: some View {
        if selection.withdrawsSpark, transfer.sparkWithdrawFeeSats != nil || transfer.isPricingSparkWithdrawal {
            FeeDisplayRow(
                label: t("lightning__savings_confirm__spark_fee"),
                amount: transfer.sparkWithdrawFeeSats ?? 0,
                isLoading: transfer.isPricingSparkWithdrawal
            )
            .padding(.top, swapState.quote == nil ? 40 : 16)
            .accessibilityIdentifier("SavingsSparkFee")
        } else if selection.withdrawsSpark || selection.isEmpty && pricesSpark && transfer.isSparkWithdrawTooSmall {
            sparkFeeError
                .padding(.top, 16)
        }
    }

    /// Spark's withdrawal fee could not be priced; the swipe waits for it, so it can be retried here. A balance too
    /// small to move after its fee has nothing to retry.
    @ViewBuilder
    private var sparkFeeError: some View {
        if transfer.isSparkWithdrawTooSmall {
            BodyMText(t("lightning__savings_confirm__amount_too_low"), textColor: .redAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("SavingsSparkTooLow")
        } else {
            sparkFeeRetry
        }
    }

    private var sparkFeeRetry: some View {
        HStack(alignment: .center, spacing: 16) {
            BodyMText(t("lightning__spending_confirm__error_quote"), textColor: .redAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
            CustomButton(title: t("common__retry"), size: .small) {
                transfer.loadSparkWithdrawFee(balanceSats: sparkSats, savingsAddress: wallet.onchainAddress)
            }
            .fixedSize()
            .accessibilityIdentifier("SavingsSparkFeeRetry")
        }
    }

    /// Commits the swipe. Asks for another swipe when Spark's withdrawal fee rose since it was shown, or is being priced
    /// again for a new balance, which the swipe shows as loading.
    private func confirmSwipe() async throws {
        do {
            try await transfer.confirmSavingsSwipe(channels: channels, withdrawsSpark: selection.withdrawsSpark)
        } catch is SavingsCommitRefused {
            throw SavingsCommitRefused()
        } catch let increase as SparkWithdrawalFeeIncreased {
            app.toast(
                type: .info,
                title: t("lightning__spending_confirm__fees_changed_title"),
                description: t(
                    "lightning__spending_confirm__fees_changed_network",
                    variables: ["amount": currency.primaryAmountText(sats: increase.feeSats - increase.shownFeeSats)]
                )
            )
            throw SpendingFeesIncreasedError()
        } catch {
            app.toast(error)
            throw error
        }
    }

    private func quoteSection(_ quote: SavingsSwapQuote) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                FeeDisplayRow(label: t("lightning__savings_confirm__network_fee"), amount: quote.networkFeeSat)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FeeDisplayRow(label: t("lightning__savings_confirm__service_fee"), amount: quote.swapFeeSat)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 16) {
                FeeDisplayRow(label: t("lightning__savings_confirm__amount"), amount: headlineSats)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FeeDisplayRow(label: t("lightning__savings_confirm__receive"), amount: receiveSats(quote))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Adjust how much to move to savings, bounded to a payable range.
            if swapState.maxSat > swapState.minSat {
                AmountSlider(
                    value: Binding(
                        get: { quote.amountSat },
                        set: { transfer.onSwapAmountChange($0) }
                    ),
                    minValue: swapState.minSat,
                    maxValue: swapState.maxSat
                )
                // Inset so the knob stays on screen at either end.
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .padding(.top, 40)
    }
}

#Preview {
    NavigationStack {
        SavingsConfirmView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(TransferViewModel())
            .environmentObject(NavigationViewModel())
    }
    .preferredColorScheme(.dark)
}
