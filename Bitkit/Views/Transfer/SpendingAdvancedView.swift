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
    @Environment(\.presentationMode) var presentationMode

    @State private var receivingSatsAmount: UInt64 = 0
    @State private var overrideSats: UInt64?
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin
    @State private var feeEstimate: UInt64?
    @State private var isValid: Bool = false

    // Constants for min/max values - these would ideally come from a service
    private let minLspBalance: UInt64 = 10000 // 10k sats minimum
    private let maxLspBalanceMultiplier: Double = 5.0 // 5x the spending capacity

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayText(NSLocalizedString("lightning__spending_advanced__title", comment: ""), accentColor: .purpleAccent)
                .padding(.top, 16)

            // Receiving capacity input
            TransferAmount(primaryDisplay: $primaryDisplay, overrideSats: $overrideSats) { newSats in
                Haptics.play(.buttonTap)
                receivingSatsAmount = newSats
                overrideSats = nil
                updateFeeEstimate()
                validateInput()
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
                        if primaryDisplay == .bitcoin {
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
                    overrideSats = minLspBalance
                }

                Spacer()

                NumberPadActionButton(text: NSLocalizedString("common__default", comment: "")) {
                    overrideSats = order.lspBalanceSat
                }

                Spacer()

                NumberPadActionButton(text: NSLocalizedString("common__max", comment: "")) {
                    overrideSats = UInt64(Double(order.clientBalanceSat) * maxLspBalanceMultiplier)
                }
            }
            .padding(.vertical)

            CustomButton(title: NSLocalizedString("common__continue", comment: ""), isDisabled: !isValid) {
                do {
                    // Create a new order with the specified receiving capacity
                    let newOrder = try await blocktank.createOrder(
                        spendingBalanceSats: order.clientBalanceSat,
                        receivingBalanceSats: receivingSatsAmount
                    )

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
            primaryDisplay = currency.primaryDisplay
            // Set initial receiving capacity to match the original order
            receivingSatsAmount = order.lspBalanceSat
            updateFeeEstimate()
            validateInput()
        }
        .onChange(of: receivingSatsAmount) { _ in
            updateFeeEstimate()
            validateInput()
        }
    }

    private func updateFeeEstimate() {
        Task {
            do {
                let estimate = try await blocktank.estimateOrderFee(
                    spendingBalanceSats: order.clientBalanceSat,
                    receivingBalanceSats: receivingSatsAmount
                )
                feeEstimate = estimate.feeSat
            } catch {
                feeEstimate = nil
                Logger.error("Failed to estimate fee: \(error.localizedDescription)")
            }
        }
    }

    private func validateInput() {
        isValid = receivingSatsAmount >= minLspBalance &&
            receivingSatsAmount <= UInt64(Double(order.clientBalanceSat) * maxLspBalanceMultiplier)
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
