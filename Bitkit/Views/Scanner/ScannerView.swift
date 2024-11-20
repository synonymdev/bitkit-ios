//
//  ScannerView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import CodeScanner
import SwiftUI

struct ScannerView: View {
    @EnvironmentObject var app: AppViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        CodeScannerView(codeTypes: [.qr], shouldVibrateOnSuccess: false) { response in
            if case .success(let result) = response {
                presentationMode.wrappedValue.dismiss()

                Task { @MainActor in
                    do {
                        let data = try await decode(invoice: result.string)

                        Haptics.play(.scanSuccess)
                        Logger.debug("Scanned data: \(data)")

                        switch data {
                        case .onChain(invoice: let invoice):
                            if let lnInvoice = invoice.params?["lightning"] as? String {
                                // Lightning invoice param found, prefer lightning payment if possible
                                if case .lightning(invoice: let lightningInvoice) = try await decode(invoice: lnInvoice) {
                                    if LightningService.shared.canSend(amountSats: lightningInvoice.amountSatoshis) {
//                                        handleLightningPayment(lightningInvoice)
                                        return
                                    }
                                }
                            }

                            // No invoice found, proceed with onchain payment
                            Logger.debug("Onchain: \(invoice)")
                        case .lightning(invoice: let invoice):
                            Logger.debug("Lightning: \(invoice)")
                            if LightningService.shared.canSend(amountSats: invoice.amountSatoshis) {
//                                handleLightningPayment(invoice)
                            } else {
                                app.toast(type: .error, title: "Insufficient Funds", description: "You do not have enough funds to send this payment.")
                            }
                        default:
                            Logger.warn("Unhandled invoice type: \(data)")
                            app.toast(type: .error, title: "Unsupported", description: "This type of invoice is not supported yet")
                        }
                    } catch {
                        Logger.error("Failed to scan data: \(error)")
                    }
                }
            }
        }
        .navigationBarTitle("Scan QR Code")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// TODO: all basic cases here for now

#Preview {
    ScannerView()
        .environmentObject(AppViewModel())
}
