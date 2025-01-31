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

                                self.dumpLdkLogs()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Confirm Order")
    }

    func dumpLdkLogs() {
        let dir = Env.ldkStorage(walletIndex: 0)
        let fileURL = dir.appendingPathComponent("ldk_node_latest.log")

        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            print("*****LDK-NODE LOG******")
            for line in lines.suffix(20) {
                print(line)
            }
        } catch {
            Logger.error(error, context: "failed to load ldk log file")
        }
    }
}

// #Preview {
//    ConfirmOrderView(order: .)
// }
