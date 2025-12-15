//
//  ReceiptDetailView.swift
//  Bitkit
//
//  Receipt detail view
//

import SwiftUI

struct ReceiptDetailView: View {
    let receipt: PaymentReceipt
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Receipt Details")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Amount Header
                    amountHeader
                    
                    // Details Card
                    detailsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
    }
    
    private var amountHeader: some View {
        VStack(spacing: 16) {
            Image(systemName: receipt.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(receipt.direction == .sent ? .redAccent : .greenAccent)
            
            BodyLText(receipt.formattedAmount)
                .foregroundColor(receipt.direction == .sent ? .redAccent : .greenAccent)
            
            StatusBadge(status: receipt.status)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailRow(label: "Counterparty", value: receipt.displayName)
            DetailRow(label: "Public Key", value: receipt.abbreviatedCounterparty)
            DetailRow(label: "Payment Method", value: receipt.paymentMethod)
            DetailRow(label: "Status", value: receipt.status.rawValue.capitalized)
            DetailRow(label: "Created", value: formatDate(receipt.createdAt))
            
            if let completedAt = receipt.completedAt {
                DetailRow(label: "Completed", value: formatDate(completedAt))
            }
            
            if let memo = receipt.memo, !memo.isEmpty {
                DetailRow(label: "Memo", value: memo)
            }
            
            if let txId = receipt.txId, !txId.isEmpty {
                DetailRow(label: "Transaction ID", value: txId)
            }
        }
        .padding(16)
        .background(Color.gray900)
        .cornerRadius(8)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            BodyMText(label)
                .foregroundColor(.textSecondary)
            
            Spacer()
            
            BodyMBoldText(value)
                .foregroundColor(.white)
                .multilineTextAlignment(.trailing)
        }
    }
}

