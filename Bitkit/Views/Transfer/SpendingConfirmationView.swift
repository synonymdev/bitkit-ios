//
//  SpendingConfirmationView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct SpendingConfirmationView: View {
    @State private var isPaying = false
    @State private var showSettingUp = false
    @State private var hideSwipeButton = false

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var transfer: TransferViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__transfer__confirm", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

                if let order = transfer.uiState.order {
                    VStack(spacing: 24) {
                        HStack {
                            FeeDisplayRow(
                                label: NSLocalizedString("lightning__spending_confirm__network_fee", comment: ""),
                                amount: order.networkFeeSat
                            )
                            .frame(maxWidth: .infinity)

                            FeeDisplayRow(
                                label: NSLocalizedString("lightning__spending_confirm__lsp_fee", comment: ""),
                                amount: order.serviceFeeSat
                            )
                            .frame(maxWidth: .infinity)
                        }

                        HStack {
                            FeeDisplayRow(
                                label: NSLocalizedString("lightning__spending_confirm__amount", comment: ""),
                                amount: order.clientBalanceSat
                            )
                            .frame(maxWidth: .infinity)

                            FeeDisplayRow(
                                label: NSLocalizedString("lightning__spending_confirm__total", comment: ""),
                                amount: order.feeSat + order.clientBalanceSat
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 16)

                    HStack(spacing: 16) {
                        NavigationLink(destination: TransferLearnMoreView(order: order)) {
                            CustomButton(title: NSLocalizedString("common__learn_more", comment: ""), size: .small)
                        }
                        NavigationLink(destination: SpendingAdvanced(order: order)) {
                            CustomButton(title: NSLocalizedString("common__advanced", comment: ""), size: .small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    if !hideSwipeButton {
                        SwipeButton(
                            title: NSLocalizedString("lightning__transfer__swipe", comment: ""),
                            accentColor: .purpleAccent
                        ) {
                            isPaying = true
                            do {
                                try await transfer.payOrder(order: order)

                                showSettingUp = true

                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    hideSwipeButton = true
                                }
                            } catch {
                                app.toast(error)
                                isPaying = false
                            }
                            isPaying = false
                        }
                        .disabled(isPaying)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            NavigationLink(destination: SettingUpView(), isActive: $showSettingUp) {
                EmptyView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(NSLocalizedString("lightning__transfer__nav_title", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    app.showFundingSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                }
            }
        }
        .background(Color.black)
    }
}

private struct FeeDisplayRow: View {
    let label: String
    let amount: UInt64

    @EnvironmentObject var currency: CurrencyViewModel

    private func formatAmount(_ number: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = " "
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    var body: some View {
        VStack(alignment: .leading) {
            BodySText(label.uppercased(), textColor: .textSecondary)
                .padding(.bottom, 6)
            if let converted = currency.convert(sats: amount) {
                let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
                BodyMBoldText("\(btcComponents.symbol) \(formatAmount(amount))")
            }
            Divider()
        }
        .padding(.trailing, 8)
    }
}

private struct SpendingDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            BodySText(label, textColor: .textSecondary)
            Spacer()
            BodySText(value)
        }
    }
}

#Preview {
    NavigationView {
        SpendingConfirmationView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .environmentObject(BlocktankViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject({
                let vm = TransferViewModel()
                vm.onOrderCreated(order: IBtOrder.mock())
                return vm
            }())
    }
    .preferredColorScheme(.dark)
}
