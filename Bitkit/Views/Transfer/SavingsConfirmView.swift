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
        SparkManager.shared.isExiting ? 0 : SparkManager.shared.balanceSats
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__transfer__confirm"), accentColor: .brandAccent)
                .fixedSize(horizontal: false, vertical: true)

            CaptionMText(t("lightning__savings_confirm__label"))
                .padding(.top, 32)
                .padding(.bottom, 16)

            MoneyText(sats: Int(headlineSats), size: .display, symbol: true)

            if let quote = swapState.quote {
                quoteSection(quote)
            }

            if selection.withdrawsSpark, transfer.sparkWithdrawFeeSats != nil || transfer.isPricingSparkWithdrawal {
                FeeDisplayRow(
                    label: t("lightning__savings_confirm__spark_fee"),
                    amount: transfer.sparkWithdrawFeeSats ?? 0,
                    isLoading: transfer.isPricingSparkWithdrawal
                )
                .padding(.top, swapState.quote == nil ? 24 : 16)
                .accessibilityIdentifier("SavingsSparkFee")
            }

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
                .padding(.top, 16)
            }

            Spacer()

            // Flexible middle: the piggybank shrinks when the fees/slider are shown and
            // gives way to a spinner while the quote loads.
            if swapState.quote == nil, swapState.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            } else {
                Image("piggybank-right")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 256, maxHeight: 256)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Spacer()

            if !hideSwipeButton, !selection.isEmpty {
                SwipeButton(
                    title: t("lightning__transfer__swipe"),
                    accentColor: .brandAccent,
                    isLoading: swapState.quote == nil && swapState.isLoading
                ) {
                    // The swipe always commits the transfer: it swaps when a quote is ready and
                    // otherwise falls back to the pre-swap behaviour of closing the channel, so it
                    // is never inert.
                    do {
                        transfer.onTransferToSavingsConfirm(channels: channels, withdrawsSpark: selection.withdrawsSpark)

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
            }

            if swapState.quote != nil {
                // Fallback: drain a whole channel on-chain by closing it instead of swapping.
                CustomButton(title: t("lightning__savings_confirm__close_instead"), variant: .tertiary) {
                    transfer.onTransferToSavingsConfirm(channels: channels, withdrawsSpark: selection.withdrawsSpark, mode: .close)
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
        .onChange(of: selection.withdrawsSpark ? sparkSats : nil, initial: true) { _, balanceSats in
            guard let balanceSats else { return }
            transfer.loadSparkWithdrawFee(balanceSats: balanceSats, savingsAddress: wallet.onchainAddress)
        }
    }

    private func quoteSection(_ quote: SavingsSwapQuote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                FeeDisplayRow(label: t("lightning__savings_confirm__network_fee"), amount: quote.networkFeeSat)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FeeDisplayRow(label: t("lightning__savings_confirm__service_fee"), amount: quote.swapFeeSat)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 16) {
                FeeDisplayRow(label: t("lightning__savings_confirm__amount"), amount: quote.amountSat)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FeeDisplayRow(label: t("lightning__savings_confirm__receive"), amount: quote.receiveSat)
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
                .padding(.top, 16)
            }
        }
        .padding(.top, 24)
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
