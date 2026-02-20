import SwiftUI

struct FundManualConfirmView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var feeEstimatesManager: FeeEstimatesManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let lnPeer: LnPeer
    let amountSats: UInt64

    // Placeholder values - in a real implementation these would be calculated
    @State private var networkFeeSat: UInt64 = 0

    private func loadFees(refresh: Bool) async {
        if let feeRates = await feeEstimatesManager.getEstimates(refresh: refresh) {
            let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeRates)
            let estimatedTxSize: UInt64 = 250 // TODO: find a way to pre calculate actual tx size
            networkFeeSat = UInt64(fastFeeRate) * estimatedTxSize
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                NavigationBar(title: t("lightning__external__nav_title"))
                    .padding(.bottom, 16)

                DisplayText(t("lightning__transfer__confirm"), accentColor: .purpleAccent)

                VStack(spacing: 16) {
                    HStack {
                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__network_fee"),
                            amount: networkFeeSat
                        )
                        .frame(maxWidth: .infinity)

                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__lsp_fee"),
                            amount: 0
                        )
                        .frame(maxWidth: .infinity)
                    }

                    HStack {
                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__amount"),
                            amount: amountSats
                        )
                        .frame(maxWidth: .infinity)

                        FeeDisplayRow(
                            label: t("lightning__spending_confirm__total"),
                            amount: amountSats + networkFeeSat
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 16)

                Spacer()

                SwipeButton(title: t("lightning__transfer__swipe"), accentColor: .purpleAccent) {
                    do {
                        let (channelId, _) = try await transfer.openManualChannel(
                            peer: lnPeer,
                            amountSats: amountSats,
                            onEvent: { eventId, handler in
                                wallet.addOnEvent(id: eventId, handler: handler)
                            },
                            removeEvent: { eventId in
                                wallet.removeOnEvent(id: eventId)
                            }
                        )

                        Logger.info("Channel opened successfully with ID: \(channelId)")

                        try await Task.sleep(nanoseconds: 500_000_000)
                        navigation.navigate(.fundManualSuccess)
                    } catch {
                        Logger.error("Failed to open channel: \(error)")
                        app.toast(error)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationBarHidden(true)
        .task {
            // Load fees first with cached data, then refresh
            await loadFees(refresh: false)
            await loadFees(refresh: true)
        }
    }
}

#Preview {
    NavigationStack {
        FundManualConfirmView(
            lnPeer: LnPeer(nodeId: "test", host: "test.com", port: 9735),
            amountSats: 50000
        )
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(CurrencyViewModel())
        .environmentObject(TransferViewModel())
        .environmentObject(FeeEstimatesManager())
    }
    .preferredColorScheme(.dark)
}
