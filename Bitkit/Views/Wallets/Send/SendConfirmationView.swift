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
    @EnvironmentObject var currency: CurrencyViewModel
    @State private var primaryDisplay: PrimaryDisplay = .bitcoin

    var body: some View {
        VStack {
            VStack(alignment: .leading) {
                if app.selectedWalletToPayFrom == .lightning, let invoice = app.scannedLightningInvoice {
                    amountView(app.sendAmountSats ?? invoice.amountSatoshis)
                    lightningView(invoice)
                } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                    amountView(app.sendAmountSats ?? invoice.amountSatoshis)
                    onchainView(invoice)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            SwipeButton(
                title: NSLocalizedString("wallet__send_swipe", comment: ""),
                accentColor: .greenAccent
            ) {
                do {
                    if app.selectedWalletToPayFrom == .lightning, let bolt11 = app.scannedLightningBolt11Invoice {
                        // A LN payment can throw an error right away, be successful right away, or take a while to complete/fail because it's retrying different paths.
                        // So we need to handle all these cases here.
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            Task {
                                do {
                                    let paymentHash = try await wallet.send(
                                        bolt11: bolt11,
                                        sats: app.sendAmountSats,
                                        onSuccess: {
                                            app.resetSendState()
                                            Logger.info("Lightning payment successful")
                                            continuation.resume()
                                        },
                                        onFail: { reason in
                                            Logger.error("Lightning payment failed: \(reason)")
                                            app.toast(type: .error, title: "Payment failed", description: reason)
                                            continuation.resume(
                                                throwing: NSError(domain: "Lightning", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
                                        }
                                    )
                                    Logger.info("Lightning send initiated with payment hash: \(paymentHash)")
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            }
                        }
                    } else if app.selectedWalletToPayFrom == .onchain, let invoice = app.scannedOnchainInvoice {
                        let sats = app.sendAmountSats ?? invoice.amountSatoshis
                        let txid = try await wallet.send(address: invoice.address, sats: sats)

                        Logger.info("Onchain send result txid: \(txid)")

                        // TODO: this send function returns instantly, find a way to check it was actually sent before reseting send state
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        app.resetSendState()
                        // TODO: once we have an onchain success event for ldk-node we don't need to trigger manually here
                        app.showNewTransactionSheet(details: .init(type: .onchain, direction: .sent, sats: sats))
                    } else {
                        throw NSError(
                            domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid payment method or missing invoice data"])
                    }
                } catch {
                    app.toast(error)
                    Logger.error("Error sending: \(error)")
                    throw error // Passing error up to SwipeButton so it knows to reset state
                }
            }
        }
        .padding()
        .sheetBackground()
        .navigationTitle(NSLocalizedString("wallet__send_review", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    func amountView(_ sats: UInt64) -> some View {
        VStack {
            AmountInput(
                defaultValue: sats,
                primaryDisplay: $primaryDisplay,
                showConversion: true
            ) { _ in
                // This is a read-only view, so we don't need to handle changes
            }
            .padding(.vertical)
            .disabled(true) // Disable interaction since this is just for display
        }
    }

    @ViewBuilder
    func toView(_ address: String) -> some View {
        VStack(alignment: .leading) {
            Text(NSLocalizedString("wallet__send_to", comment: ""))
                .foregroundColor(.secondary)
                .font(.caption)
            Text(address)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical)
    }

    @ViewBuilder
    func onchainView(_ invoice: OnChainInvoice) -> some View {
        VStack {
            toView(invoice.address)

            // Divider()

            // HStack {
            //     VStack(alignment: .leading) {
            //         Text("Speed and fee")
            //             .foregroundColor(.secondary)
            //             .font(.caption)
            //         Text("TODO")
            //     }
            //     Spacer()
            //     VStack(alignment: .leading) {
            //         Text("Confirming in")
            //             .foregroundColor(.secondary)
            //             .font(.caption)
            //         Text("TODO")
            //     }
            // }
            // .padding(.vertical)

            Divider()
        }
    }

    @ViewBuilder
    func lightningView(_: LightningInvoice) -> some View {
        VStack {
            toView(app.scannedLightningBolt11Invoice ?? "")

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("wallet__send_fee_and_speed", comment: ""))
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("1")
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("Confirms in")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("1 second")
                }
            }
            .padding(.vertical)

            Divider()
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationView {
                    SendConfirmationView()
                        .environmentObject(AppViewModel())
                        .environmentObject(WalletViewModel())
                        .environmentObject(
                            {
                                let vm = CurrencyViewModel()
                                vm.primaryDisplay = .bitcoin
                                return vm
                            }())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
