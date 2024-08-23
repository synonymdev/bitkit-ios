//
//  ReceiveQR.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct ReceiveQR: View {
    @ObservedObject var wallet = WalletViewModel.shared

    var body: some View {
        VStack {
            Text("Receive Bitcoin")
                .padding()

            if let bip21 = wallet.bip21 {
                QR(content: bip21)
                    .frame(maxWidth: .infinity)
                    .padding()

                Button("Copy") {
                    UIPasteboard.general.string = bip21
                }

            } else {
                ProgressView()
            }
        }
        .task {
            if wallet.onchainAddress == nil {
                do {
                    try await wallet.createBip21()
                } catch {
                    // TODO: Show error notification
                    Logger.error(error)
                }
            }
        }
    }
}

#Preview {
    ReceiveQR()
}
