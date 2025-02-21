//
//  SpendingConfirmationView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct SpendingConfirmationView: View {
    let order: IBtOrder

    @State private var isPaying = false
    @State private var txId = ""
    @State private var showAdvanced = false
    @State private var showLearnMore = false
    @State private var showSettingUp = false
    @State private var hideSwipeButton = false

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                DisplayText(NSLocalizedString("lightning__transfer__confirm", comment: ""), accentColor: .purpleAccent)
                    .padding(.top, 16)

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
                    CustomButton(title: NSLocalizedString("common__learn_more", comment: ""), size: .small) {
                        showLearnMore = true
                    }
                    CustomButton(title: NSLocalizedString("common__advanced", comment: ""), size: .small) {
                        showAdvanced = true
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
                            txId = try await wallet.send(
                                address: order.payment.onchain.address,
                                sats: order.feeSat
                            )
                            showSettingUp = true

                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                hideSwipeButton = true
                            }
                        } catch {
                            app.toast(error)
                            throw error
                        }
                        isPaying = false
                    }
                    .disabled(isPaying)
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
        SpendingConfirmationView(order: IBtOrder(
            id: "order123",
            state: .created,
            state2: .created,
            feeSat: 1000,
            networkFeeSat: 2483,
            serviceFeeSat: 1520,
            lspBalanceSat: 50000,
            clientBalanceSat: 85967,
            zeroConf: false,
            zeroReserve: false,
            clientNodeId: "node123",
            channelExpiryWeeks: 52,
            channelExpiresAt: "2025-03-14",
            orderExpiresAt: "2024-03-21",
            channel: nil,
            lspNode: .init(alias: "", pubkey: "", connectionStrings: [], readonly: nil),
            lnurl: nil,
            payment: IBtPayment(
                state: .created,
                state2: .created,
                paidSat: 0,
                bolt11Invoice: IBtBolt11Invoice(
                    request: "lnbc...",
                    state: .pending,
                    expiresAt: "2024-03-21",
                    updatedAt: "2024-03-14"
                ),
                onchain: IBtOnchainTransactions(
                    address: "bc1q...",
                    confirmedSat: 0,
                    requiredConfirmations: 3,
                    transactions: []
                ),
                isManuallyPaid: nil,
                manualRefunds: nil
            ),
            couponCode: nil,
            source: nil,
            discount: nil,
            updatedAt: "2024-03-14",
            createdAt: "2024-03-14"
        ))
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(BlocktankViewModel())
        .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
