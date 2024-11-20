//
//  SendConfirmationView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/11/19.
//

import SwiftUI

struct SendConfirmationView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        VStack {
            VStack(alignment: .leading) {
                if let invoice = app.scannedLightningInvoice {
                    amountView(app.sendAmountSats ?? invoice.amountSatoshis)
                    lightningView(invoice)
                } else if let invoice = app.scannedOnchainInvoice {
                    amountView(app.sendAmountSats ?? invoice.amountSatoshis)
                    onchainView(invoice)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            SwipeButton {
                do {
                    if let _ = app.scannedLightningInvoice, let bolt11 = app.scannedLightningBolt11Invoice {
                        let paymentHash = try await wallet.send(bolt11: bolt11, sats: app.sendAmountSats) // If sendAmountSats is nil that implies it's a non zero invoice
                        Logger.info("Lightning send result payment hash: \(paymentHash)")
                    } else if let invoice = app.scannedOnchainInvoice {
                        let txid = try await wallet.send(address: invoice.address, sats: app.sendAmountSats ?? invoice.amountSatoshis)

                        Logger.info("Onchain send result txid: \(txid)")

                        // TODO: this send function returns instantly, find a way to check it was actually sent before reseting send state
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        app.resetSendState()
                    }
                } catch {
                    app.toast(error)
                    Logger.error("Error sending: \(error)")
                    throw error // Passing error up to SwipeButton so it knows to reset state
                }
            }
        }
        .padding()
        .navigationTitle("Review and Send")
    }

    @ViewBuilder
    func amountView(_ sats: UInt64) -> some View {
        VStack {
            Text("\(sats) sats")
                .font(.title)
        }
    }

    @ViewBuilder
    func toView(_ address: String) -> some View {
        VStack(alignment: .leading) {
            Text("To")
                .foregroundColor(.secondary)
                .font(.caption)
            Text(address)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical)
    }

    @ViewBuilder
    func onchainView(_ invoice: OnChainInvoice) -> some View {
        VStack {
            toView(invoice.address)

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Speed and fee")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("TODO")
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("Confirming in")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("TODO")
                }
            }
            .padding(.vertical)

            Divider()
        }
    }

    @ViewBuilder
    func lightningView(_ invoice: LightningInvoice) -> some View {
        VStack {
            // Add lightning invoice details here
        }
    }
}

#Preview {
    SendConfirmationView()
}
