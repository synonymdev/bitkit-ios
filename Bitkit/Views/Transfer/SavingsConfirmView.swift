import LDKNode
import SwiftUI

struct SavingsConfirmView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var hideSwipeButton = false

    private var hasMultipleChannels: Bool {
        guard let channels = wallet.channels else { return false }
        return channels.filter(\.isChannelReady).count > 1
    }

    private var hasSelectedChannels: Bool {
        return !transfer.selectedChannelIds.isEmpty
    }

    private var channels: [ChannelDetails] {
        guard let channels = wallet.channels else { return [] }
        let usableChannels = channels.filter(\.isChannelReady)

        if transfer.selectedChannelIds.isEmpty {
            return usableChannels
        } else {
            return usableChannels.filter { transfer.selectedChannelIds.contains($0.channelId) }
        }
    }

    private var totalSats: UInt64 {
        channels.reduce(0) { $0 + $1.balanceOnCloseSats }
    }

    private var swapState: SavingsSwapState {
        transfer.savingsSwapState
    }

    private var headlineSats: UInt64 {
        swapState.quote?.amountSat ?? totalSats
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
            } else if let errorMessage = swapState.errorMessage {
                BodySText(errorMessage)
                    .padding(.top, 16)
            }

            if hasMultipleChannels {
                HStack(spacing: 16) {
                    if hasSelectedChannels {
                        CustomButton(title: t("lightning__savings_confirm__transfer_all"), size: .small) {
                            transfer.setSelectedChannelIds([])
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

            if !hideSwipeButton {
                SwipeButton(
                    title: t("lightning__transfer__swipe"),
                    accentColor: .brandAccent
                ) {
                    // Swapping funds out is the default; it only fires once the fee quote is ready.
                    guard swapState.quote != nil else { return }

                    do {
                        transfer.savingsTransferMode = .swap
                        transfer.onTransferToSavingsConfirm(channels: channels)

                        try await Task.sleep(nanoseconds: 300_000_000)

                        navigation.navigate(.savingsProgress)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            hideSwipeButton = true
                        }
                    } catch {
                        app.toast(error)
                    }
                }
            }

            // Fallback: drain a whole channel on-chain by closing it instead of swapping.
            CustomButton(title: t("lightning__savings_confirm__close_instead"), variant: .tertiary) {
                transfer.savingsTransferMode = .close
                transfer.onTransferToSavingsConfirm(channels: channels)
                navigation.navigate(.savingsProgress)
            }
            .padding(.top, 12)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .task(id: totalSats) {
            // Pull the latest node balances so a just-received payment is reflected, then
            // present the swap fee before the user commits. Recomputed when the amount changes.
            await wallet.syncStateAsync()
            guard totalSats > 0 else { return }
            await transfer.loadSavingsSwapQuote(
                requestedSat: totalSats,
                spendableSats: UInt64(max(0, wallet.maxSendLightningSats))
            )
        }
    }

    @ViewBuilder
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
