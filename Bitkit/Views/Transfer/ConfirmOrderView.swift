//
//  ConfirmOrderView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct ConfirmOrderView: View {
    let order: BtOrder

    @State private var isPaying = false
    @State private var txId = ""

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var toast: ToastViewModel

    var body: some View {
        Form {
            Section {
                Text("Order ID: \(order.id)")
                Text("Fees: \(order.feeSat) sats")
                Text("Spending: \(order.clientBalanceSat) sats")
                Text("Receiving: \(order.lspBalanceSat) sats")
            }

            if txId.isEmpty {
                Section {
                    Button(isPaying ? "Transfering" : "Confirm") {
                        Task { @MainActor in
                            isPaying = true

                            do {
                                txId = try await wallet.send(
                                    address: order.payment.onchain.address,
                                    sats: order.feeSat
                                )

                                // TODO: tell BT model to watch this order for payment
                            } catch {
                                toast.show(error)
                            }

                            isPaying = false
                        }
                    }
                    .disabled(isPaying)
                }
            } else {
                Section {
                    Text("Payment sent: \(txId)")
                    Text("You can close the app now. We will notify you when the channel is ready.")
                }

                Section {
                    Button("Try manual open") {
                        Task {
                            do {
                                try await BlocktankService.shared.openChannel(orderId: order.id)
                            } catch {
                                toast.show(error)
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
