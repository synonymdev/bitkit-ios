//
//  SpendingAdvancedView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct SpendingAdvancedView: View {
    let order: IBtOrder
    var onOrderCreated: (IBtOrder) -> Void

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var receivingSatsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var feeEstimate: UInt64?

    private var isValid: Bool {
        let isAboveMin = receivingSatsAmount >= transfer.transferValues.minLspBalance
        let isBelowMax = receivingSatsAmount <= transfer.transferValues.maxLspBalance

        let result = isAboveMin && isBelowMax
        // Logger.debug("isValid computed - receivingSatsAmount: \(receivingSatsAmount)")
        // Logger.debug("Min LSP balance: \(transfer.transferValues.minLspBalance)")
        // Logger.debug("Max LSP balance: \(transfer.transferValues.maxLspBalance)")
        // Logger.debug("Is above min? \(isAboveMin), Is below max? \(isBelowMax)")
        // Logger.debug("defaultLspBalance: \(transfer.transferValues.defaultLspBalance)")
        // Logger.debug("isValid result: \(result)")

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayText(NSLocalizedString("lightning__spending_advanced__title", comment: ""), accentColor: .purpleAccent)
                .padding(.top, 16)

            // Receiving capacity input
            TransferAmount(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats) { newSats in
                Haptics.play(.buttonTap)
                receivingSatsAmount = newSats
                overrideSats = nil
                updateFeeEstimate()
            }
            .padding(.vertical, 8)

            // Fee estimate
            HStack(spacing: 4) {
                CaptionText(
                    NSLocalizedString("lightning__spending_advanced__fee", comment: "").uppercased(),
                    textColor: .white64
                )

                if let feeEstimate = feeEstimate {
                    if let converted = currency.convert(sats: feeEstimate) {
                        if currency.primaryDisplay == .bitcoin {
                            let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                            CaptionText("\(btcComponents.symbol) \(feeEstimate)", textColor: .white)
                        } else {
                            CaptionText("\(converted.symbol) \(converted.formatted)", textColor: .white)
                        }
                    }
                } else {
                    CaptionText("—", textColor: .white64)
                }
            }
            .frame(height: 20)
            .padding(.bottom, 8)

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                NumberPadActionButton(text: NSLocalizedString("common__min", comment: "")) {
                    Logger.debug("Min button pressed, setting to: \(transfer.transferValues.minLspBalance)")
                    overrideSats = transfer.transferValues.minLspBalance
                }

                Spacer()

                NumberPadActionButton(text: NSLocalizedString("common__default", comment: "")) {
                    Logger.debug("Default button pressed, setting to: \(transfer.transferValues.defaultLspBalance)")
                    overrideSats = transfer.transferValues.defaultLspBalance
                }

                Spacer()

                NumberPadActionButton(text: NSLocalizedString("common__max", comment: "")) {
                    Logger.debug("Max button pressed, setting to: \(transfer.transferValues.maxLspBalance)")
                    overrideSats = transfer.transferValues.maxLspBalance
                }
            }
            .padding(.vertical)

            CustomButton(
                title: NSLocalizedString("common__continue", comment: ""),
                isDisabled: !isValid
            ) {
                do {
                    // Create a new order with the specified receiving capacity
                    let newOrder = try await blocktank.createOrder(
                        spendingBalanceSats: order.clientBalanceSat,
                        receivingBalanceSats: receivingSatsAmount
                    )

                    transfer.onAdvancedOrderCreated(order: newOrder)
                    onOrderCreated(newOrder)
                    presentationMode.wrappedValue.dismiss()
                } catch {
                    app.toast(error)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
        .background(Color.black)
        .task {
            transfer.updateTransferValues(
                clientBalanceSat: order.clientBalanceSat,
                blocktankInfo: blocktank.info
            )

            // Set initial receiving capacity to the default LSP balance
            receivingSatsAmount = transfer.transferValues.defaultLspBalance
            overrideSats = transfer.transferValues.defaultLspBalance
            updateFeeEstimate()
        }
        .onChange(of: receivingSatsAmount) { _ in
            updateFeeEstimate()
        }
    }

    private func updateFeeEstimate() {
        Logger.debug("Starting fee estimate update for receivingSatsAmount: \(receivingSatsAmount)")
        Task {
            do {
                let estimate = try await blocktank.estimateOrderFee(
                    spendingBalanceSats: order.clientBalanceSat,
                    receivingBalanceSats: receivingSatsAmount
                )
                feeEstimate = estimate.feeSat
                Logger.debug("Fee estimate updated successfully: \(estimate.feeSat)")
            } catch {
                feeEstimate = nil
                Logger.error("Failed to estimate fee: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    NavigationView {
        SpendingAdvancedView(order: IBtOrder.mock(lspBalanceSat: 100_000, clientBalanceSat: 50000), onOrderCreated: { _ in

        })
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(CurrencyViewModel())
        .environmentObject(BlocktankViewModel())
        .environmentObject(TransferViewModel())
    }
    .preferredColorScheme(.dark)
}
