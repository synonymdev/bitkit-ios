//
//  ScannerView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import CodeScanner
import SwiftUI

struct ScannerView: View {
    @Binding var showSendAmountView: Bool
    @Binding var showSendConfirmationView: Bool
    var onResultDelay: TimeInterval = 0

    @EnvironmentObject private var app: AppViewModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CodeScannerView(codeTypes: [.qr], shouldVibrateOnSuccess: false) { response in
            if case .success(let result) = response {
                presentationMode.wrappedValue.dismiss()

                handleScan(result.string)
            } else if case .failure(let error) = response {
                Logger.error(error, context: "Failed to scan QR code")
                app.toast(error)
            }
        }
        .navigationBarTitle("Scan QR Code")
        .navigationBarTitleDisplayMode(.inline)
    }

    func handleScan(_ uri: String) {
        Haptics.play(.scanSuccess)

        Task { @MainActor in
            do {
                try await app.handleScannedData(uri)

                DispatchQueue.main.asyncAfter(deadline: .now() + onResultDelay) {
                    // If nil then it's not an invoice we're dealing with
                    if app.invoiceRequiresCustomAmount == true {
                        showSendAmountView = true
                    } else if app.invoiceRequiresCustomAmount == false {
                        showSendConfirmationView = true
                    }
                }
            } catch {
                Logger.error(error, context: "Failed to read data from QR")
                app.toast(error)
            }
        }
    }
}

#Preview {
    ScannerView(
        showSendAmountView: .constant(false),
        showSendConfirmationView: .constant(false)
    )
    .environmentObject(AppViewModel())
}
