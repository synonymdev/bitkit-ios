//
//  ScannerView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import CodeScanner
import SwiftUI

struct ScannerView: View {
    let onDecodeSuccess: () -> Void

    @EnvironmentObject var app: AppViewModel
    @Environment(\.presentationMode) var presentationMode

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

                onDecodeSuccess()
            } catch {
                Logger.error(error, context: "Failed to read data from QR")
                app.toast(error)
            }
        }
    }
}

// TODO: all basic cases here for now

#Preview {
    ScannerView {}
        .environmentObject(AppViewModel())
}
