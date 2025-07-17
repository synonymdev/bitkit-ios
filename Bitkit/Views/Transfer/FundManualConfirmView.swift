import SwiftUI

struct FundManualConfirmView: View {
    @State private var showSuccess = false
    @State private var hideSwipeButton = false

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel

    let lnPeer: LnPeer
    let satsAmount: UInt64

    // Placeholder values - in a real implementation these would be calculated
    @State private var networkFeeSat: UInt64 = 0

    private func loadFees(refresh: Bool) async {
        do {
            let coreService = CoreService.shared
            if let feeRates = try await coreService.blocktank.fees(refresh: refresh) {
                let fastSatsPerVbyte = feeRates.getSatsPerVbyte(for: .fast)
                let estimatedTxSize: UInt64 = 250 // TODO: find a way to pre calculate actual tx size
                networkFeeSat = UInt64(fastSatsPerVbyte) * estimatedTxSize
            }
        } catch {
            Logger.error("Failed to fetch fee rates: \(error)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__transfer__confirm", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                VStack(spacing: 16) {
                    HStack {
                        FeeDisplayRow(
                            label: NSLocalizedString("lightning__spending_confirm__network_fee", comment: ""),
                            amount: networkFeeSat
                        )
                        .frame(maxWidth: .infinity)

                        FeeDisplayRow(
                            label: NSLocalizedString("lightning__spending_confirm__lsp_fee", comment: ""),
                            amount: 0
                        )
                        .frame(maxWidth: .infinity)
                    }

                    HStack {
                        FeeDisplayRow(
                            label: NSLocalizedString("lightning__spending_confirm__amount", comment: ""),
                            amount: satsAmount
                        )
                        .frame(maxWidth: .infinity)

                        FeeDisplayRow(
                            label: NSLocalizedString("lightning__spending_confirm__total", comment: ""),
                            amount: satsAmount + networkFeeSat
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 16)

                Spacer()

                if !hideSwipeButton {
                    SwipeButton(
                        title: NSLocalizedString("lightning__transfer__swipe", comment: ""),
                        accentColor: .purpleAccent
                    ) {
                        do {
                            let lightningService = LightningService.shared

                            // Open a channel with the given peer and amount
                            try await lightningService.openChannel(
                                peer: lnPeer,
                                channelAmountSats: satsAmount
                            )

                            Logger.info("Channel opened successfully")
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                            showSuccess = true

                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                hideSwipeButton = true
                            }
                        } catch {
                            Logger.error("Failed to open channel: \(error)")
                            app.toast(error)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            NavigationLink(destination: FundManualSuccessView(), isActive: $showSuccess) {
                EmptyView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__connections", comment: ""))
        .backToWalletButton()
        .background(Color.black)
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
            satsAmount: 50000
        )
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(CurrencyViewModel())
        .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}
