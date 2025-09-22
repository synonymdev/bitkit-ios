import BitkitCore
import SwiftUI

struct GiftLoading: View {
    @Binding var navigationPath: [GiftRoute]
    @EnvironmentObject private var activity: ActivityListViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    let code: String
    let amount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("other__gift__claiming__title"))

            VStack(spacing: 0) {
                MoneyStack(sats: amount, showSymbol: true)

                BodyMText(t("other__gift__claiming__text"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 32)

                Spacer()

                Image("gift-figure")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIScreen.main.bounds.width * 0.8)
                    .frame(maxHeight: 256)

                Spacer()

                ActivityIndicator()
                    .padding(.bottom, 32)
            }
        }
        .padding(.horizontal, 16)
        .accessibilityIdentifier("GiftLoading")
        .task {
            await claimGift()
        }
    }

    private func claimGift() async {
        // Wait for peers to be connected (equivalent to waitForLdkPeers)
        await waitForPeers()

        let maxInboundCapacity = wallet.totalInboundLightningSats ?? 0

        Logger.debug("Max inbound capacity: \(maxInboundCapacity)")

        if maxInboundCapacity >= UInt64(amount) {
            // User has sufficient inbound capacity, use existing channels
            await claimWithLiquidity()
        } else {
            // User needs new channel, create order
            await claimWithoutLiquidity()
        }
    }

    private func waitForPeers() async {
        // Wait a bit for peers to connect if node is starting
        guard wallet.nodeLifecycleState == .running else {
            // Wait for node to be running
            _ = await wallet.waitForNodeToRun(timeoutSeconds: 30.0)
            return
        }

        // Give some time for peer connections
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
    }

    private func claimWithLiquidity() async {
        do {
            // Create a lightning invoice for the gift amount
            let invoice = try await wallet.createInvoice(note: "blocktank-gift-code:\(code)")

            // Pay the gift using the invoice
            do {
                Logger.debug("Calling giftPay with invoice: \(invoice)")
                let result = try await giftPay(invoice: invoice)
                Logger.info("giftPay function completed successfully")
                Logger.info("Gift payment result: \(result)")

                // if result {
                //     // Gift payment successful, close the sheet
                //     sheets.hideSheet()
                // } else {
                //     // Payment failed
                //     navigationPath.append(.error)
                // }
            } catch {
                Logger.error("giftPay function failed with error: \(error)")
                Logger.error("giftPay error type: \(type(of: error))")
                throw error
            }
        } catch {
            Logger.error("Gift claim with liquidity failed: \(error)")

            // Check the full error description for gift code error types
            let errorDescription = String(describing: error)
            if errorDescription.contains("GIFT_CODE_ALREADY_USED") {
                navigationPath.append(.used)
            } else if errorDescription.contains("GIFT_CODE_USED_UP") {
                navigationPath.append(.usedUp)
            } else {
                navigationPath.append(.failed)
            }
        }
    }

    private func claimWithoutLiquidity() async {
        do {
            Logger.debug("Starting claimWithoutLiquidity with code: '\(code)', amount: \(amount)")

            guard let nodeId = LightningService.shared.nodeId else {
                throw AppError(serviceError: .nodeNotStarted)
            }

            // Create an order for the gift using BitkitCore
            Logger.debug("Calling giftOrder with clientNodeId: \(nodeId), code: \(code)")
            let order = try await giftOrder(clientNodeId: nodeId, code: "blocktank-gift-code:\(code)")
            Logger.debug("giftOrder completed successfully")

            // Open the channel
            let openedOrder = try await CoreService.shared.blocktank.open(orderId: order.id)

            Logger.debug("Opened order: \(openedOrder)")

            // Create activity item for the received gift
            let lightningActivity = LightningActivity(
                id: openedOrder.channel?.fundingTx.id ?? order.id,
                txType: .received,
                status: .succeeded,
                value: UInt64(amount),
                fee: nil,
                invoice: "",
                message: code,
                timestamp: UInt64(Date().timeIntervalSince1970),
                preimage: nil,
                createdAt: UInt64(Date().timeIntervalSince1970),
                updatedAt: UInt64(Date().timeIntervalSince1970)
            )

            // Add to activity list
            try await CoreService.shared.activity.insert(.lightning(lightningActivity))

            // Trigger haptic feedback
            Haptics.notify(.success)

            // Close gift sheet and show received transaction sheet
            sheets.hideSheet()
            sheets.showSheet(.receivedTx, data: ReceivedTxSheetDetails(type: .lightning, sats: UInt64(amount)))
        } catch {
            Logger.error("Gift claim without liquidity failed: \(error)")

            // Check the full error description for gift code error types
            let errorDescription = String(describing: error)
            if errorDescription.contains("GIFT_CODE_ALREADY_USED") {
                navigationPath.append(.used)
            } else if errorDescription.contains("GIFT_CODE_USED_UP") {
                navigationPath.append(.usedUp)
            } else {
                navigationPath.append(.failed)
            }
        }
    }
}
