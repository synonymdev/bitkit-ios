//
//  ReceiptDetailLookupView.swift
//  Bitkit
//
//  Helper view that looks up a receipt by ID and displays ReceiptDetailView
//

import SwiftUI

struct ReceiptDetailLookupView: View {
    let receiptId: String
    
    @State private var receipt: PaymentReceipt?
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let receipt = receipt {
                ReceiptDetailView(receipt: receipt)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.textSecondary)
                    
                    BodyLText("Receipt Not Found")
                        .foregroundColor(.textPrimary)
                    
                    BodyMText("The receipt with ID \(receiptId) could not be found.")
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            }
        }
        .task {
            await loadReceipt()
        }
    }
    
    private func loadReceipt() async {
        let storage = ReceiptStorage(identityName: "default")
        receipt = storage.getPaymentReceipt(id: receiptId)
        isLoading = false
    }
}

