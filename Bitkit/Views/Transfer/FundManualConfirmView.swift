import SwiftUI

struct FundManualConfirmView: View {
    @State private var showSuccess = false
    @State private var hideSwipeButton = false

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var transferTracking: TransferTrackingManager

    let lnPeer: LnPeer
    let amountSats: UInt64

    // Placeholder values - in a real implementation these would be calculated
    @State private var networkFeeSat: UInt64 = 0

    private func loadFees(refresh: Bool) async {
        do {
            let coreService = CoreService.shared
            if let feeRates = try await coreService.blocktank.fees(refresh: refresh) {
                let fastFeeRate = TransactionSpeed.fast.getFeeRate(from: feeRates)
                let estimatedTxSize: UInt64 = 250 // TODO: find a way to pre calculate actual tx size
                networkFeeSat = UInt64(fastFeeRate) * estimatedTxSize
            }
        } catch {
            Logger.error("Failed to fetch fee rates: \(error)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                NavigationBar(title: t("lightning__connections"))

                DisplayText(t("lightning__transfer__confirm"), accentColor: .purpleAccent)
                    .padding(.top, 16)

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

                if !hideSwipeButton {
                    SwipeButton(
                        title: t("lightning__transfer__swipe"),
                        accentColor: .purpleAccent
                    ) {
                        do {
                            let lightningService = LightningService.shared

                            // Open a channel with the given peer and amount
                            let channelId = try await lightningService.openChannel(
                                peer: lnPeer,
                                channelAmountSats: amountSats
                            )

                            Logger.info("Channel opened successfully with ID: \(channelId)")

                            // Use an actor to safely capture the funding transaction ID
                            let fundingTxCapture = FundingTxCapture()
                            let eventId = "manual-channel-funding-\(channelId)"

                            wallet.addOnEvent(id: eventId) { event in
                                if case let .channelPending(
                                    eventChannelId,
                                    userChannelId,
                                    formerTemporaryChannelId,
                                    counterpartyNodeId,
                                    fundingTxo
                                ) = event {
                                    // Validate this is the channel we just opened
                                    if eventChannelId.description == channelId {
                                        Task {
                                            await fundingTxCapture.setFundingTxId(fundingTxo.txid.description)
                                            Logger.debug(
                                                "Captured funding tx ID: \(fundingTxo.txid.description) for channel: \(channelId)",
                                                context: "FundManualConfirmView"
                                            )
                                        }
                                    }
                                }
                            }

                            let fundingTxId = await waitForFundingTx(
                                capture: fundingTxCapture,
                                maxAttempts: 10,
                                initialDelayMs: 50
                            )

                            wallet.removeOnEvent(id: eventId)

                            if fundingTxId == nil {
                                Logger.warn("Timeout waiting for funding tx ID for channel: \(channelId)", context: "FundManualConfirmView")
                            }

                            // Create transfer tracking record for manual channel opening
                            do {
                                let transferId = try await transferTracking.createTransfer(
                                    type: .toSpending,
                                    amountSats: amountSats,
                                    channelId: channelId,
                                    fundingTxId: fundingTxId
                                )
                                Logger.info(
                                    "Created transfer tracking record: \(transferId) with fundingTxId: \(fundingTxId ?? "nil")",
                                    context: "FundManualConfirmView"
                                )
                            } catch {
                                Logger.error("Failed to create transfer tracking record", context: error.localizedDescription)
                                // Don't throw - we still want to show success even if tracking fails
                            }

                            try await Task.sleep(nanoseconds: 500_000_000)
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
        .navigationBarHidden(true)
        .task {
            // Load fees first with cached data, then refresh
            await loadFees(refresh: false)
            await loadFees(refresh: true)
        }
    }
}

/// Actor to safely capture funding transaction ID from event callbacks
/// Ensures thread-safe access when the event callback may execute on different threads
private actor FundingTxCapture {
    private var fundingTxId: String?

    func setFundingTxId(_ txId: String) {
        fundingTxId = txId
    }

    func getFundingTxId() -> String? {
        return fundingTxId
    }
}

/// Wait for funding transaction ID with exponential backoff
/// - Parameters:
///   - capture: The actor holding the funding tx ID
///   - maxAttempts: Maximum number of polling attempts
///   - initialDelayMs: Initial delay in milliseconds (will be doubled each attempt)
/// - Returns: The funding transaction ID if captured, nil if timeout
private func waitForFundingTx(
    capture: FundingTxCapture,
    maxAttempts: Int,
    initialDelayMs: UInt64
) async -> String? {
    var delayMs = initialDelayMs

    for attempt in 1 ... maxAttempts {
        // Check if we have the funding tx ID
        if let txId = await capture.getFundingTxId() {
            Logger.debug("Got funding tx ID on attempt \(attempt)", context: "FundManualConfirmView")
            return txId
        }

        // Don't sleep after the last attempt
        guard attempt < maxAttempts else { break }

        // Sleep with exponential backoff
        let delayNs = delayMs * 1_000_000 // Convert ms to nanoseconds
        do {
            try await Task.sleep(nanoseconds: delayNs)
        } catch {
            Logger.debug("Sleep interrupted while waiting for funding tx", context: "FundManualConfirmView")
            break
        }

        // Exponential backoff: double the delay, max 2 seconds
        delayMs = min(delayMs * 2, 2000)
    }

    return nil
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
        .environmentObject(TransferTrackingManager(service: TransferService(
            lightningService: LightningService.shared,
            blocktankService: CoreService.shared.blocktank
        )))
    }
    .preferredColorScheme(.dark)
}
