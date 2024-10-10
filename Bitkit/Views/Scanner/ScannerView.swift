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
            if case let .success(result) = response {
                presentationMode.wrappedValue.dismiss()

                do {
                    let scannedData = try ScannedData(result.string)
                    Logger.debug("Scanned data: \(scannedData)")
                    Haptics.play(.scanSuccess)
                    app.scannedData = scannedData
                    app.showSendSheet = true
                } catch {
                    Logger.error("Failed to scan data: \(error)")
                }
            }
        }
    }
}

// TODO: all basic cases here for now

#Preview {
    ScannerView()
        .environmentObject(AppViewModel())
}
