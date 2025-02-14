//
//  ConfirmOrderView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct ConfirmOrderView_OLD: View {
    let order: IBtOrder

    @State private var isPaying = false
    @State private var txId = ""

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        Form {
            Section {
                Text("Order ID: \(self.order.id)")
                Text("Fees: \(self.order.feeSat) sats")
                Text("Spending: \(self.order.clientBalanceSat) sats")
                Text("Receiving: \(self.order.lspBalanceSat) sats")
            }

            if self.txId.isEmpty {
                Section {
                    Button(self.isPaying ? "Transfering" : "Confirm") {
                        Task { @MainActor in
                            self.isPaying = true

                            do {
                                self.txId = try await self.wallet.send(
                                    address: self.order.payment.onchain.address,
                                    sats: self.order.feeSat
                                )

                                // TODO: tell BT model to watch this order for payment
                            } catch {
                                self.app.toast(error)
                            }

                            self.isPaying = false
                        }
                    }
                    .disabled(self.isPaying)
                }
            } else {
                Section {
                    Text("Payment sent: \(self.txId)")
                    Text("You can close the app now. We will notify you when the channel is ready.")
                }

                Section {
                    Button("Try manual open") {
                        Task {
                            do {
                                let _ = try await CoreService.shared.blocktank.open(orderId: self.order.id)
                            } catch {
                                self.app.toast(error)

                                LightningService.shared.dumpLdkLogs()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Confirm Order")
    }
}

// #Preview {
//    ConfirmOrderView(order: .)
// }
