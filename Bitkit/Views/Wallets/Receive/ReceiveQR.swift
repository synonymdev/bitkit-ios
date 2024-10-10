//
//  ReceiveQR.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct ReceiveQR: View {
    @State var isCreatingInvoice = false

    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var toast: ToastViewModel

    var body: some View {
        VStack {
            Text("Receive Bitcoin")
                .padding()
                .onAppear {
                    toast.show(type: .error, title: "TEST", description: "TEST")
                }
            if let bip21 = wallet.bip21 {
                QR(content: bip21)
                    .frame(maxWidth: .infinity)
                    .padding()

                Button("Copy") {
                    UIPasteboard.general.string = bip21
                    Haptics.play(.copiedToClipboard)
                }
            } else {
                ProgressView()
            }

            if let nodeId = wallet.nodeId {
                Button("Create and copy CJIT invoice") {
                    Task { @MainActor in
                        isCreatingInvoice = true
                        do {
                            let entry = try await BlocktankService.shared.createCJitEntry(
                                channelSizeSat: 120000,
                                invoiceSat: 6000,
                                invoiceDescription: "Pay me",
                                nodeId: nodeId,
                                channelExpiryWeeks: 2,
                                options: .init()
                            )
                            UIPasteboard.general.string = entry.invoice.request
                            Haptics.play(.copiedToClipboard)
                        } catch {
                            Logger.error(error)
                            Haptics.notify(.error)
                        }
                        isCreatingInvoice = false
                    }
                }
                .disabled(isCreatingInvoice)

                Button("Create and copy bolt11") {
                    Task { @MainActor in
                        do {
                            let invoice = try await LightningService.shared.receive(amountSats: 5000, description: "paymeplz")
                            UIPasteboard.general.string = invoice
                            Haptics.play(.copiedToClipboard)
                        } catch {
                            toast.show(error)
                        }
                    }
                }
            }
        }
        .task {
            if wallet.onchainAddress == nil {
                do {
                    try await wallet.createBip21()
                } catch {
                    toast.show(error)
                }
            }
        }
    }
}

#Preview {
    ReceiveQR()
        .environmentObject(WalletViewModel())
        .environmentObject(ToastViewModel())
}
