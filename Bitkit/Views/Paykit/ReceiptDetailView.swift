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
            
            ReceiptStatusBadge(status: receipt.status)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReceiptDetailRow(label: "Counterparty", value: receipt.displayName)
            ReceiptDetailRow(label: "Public Key", value: receipt.abbreviatedCounterparty)
            ReceiptDetailRow(label: "Payment Method", value: receipt.paymentMethod)
            ReceiptDetailRow(label: "Status", value: receipt.status.rawValue.capitalized)
            ReceiptDetailRow(label: "Created", value: formatDate(receipt.createdAt))
            
            if let completedAt = receipt.completedAt {
                ReceiptDetailRow(label: "Completed", value: formatDate(completedAt))
            }
            
            if let memo = receipt.memo, !memo.isEmpty {
                ReceiptDetailRow(label: "Memo", value: memo)
            }
            
            if let txId = receipt.txId, !txId.isEmpty {
                ReceiptDetailRow(label: "Transaction ID", value: txId)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(8)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ReceiptDetailRow: View {
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

struct ReceiptStatusBadge: View {
    let status: PaymentReceiptStatus
    
    var body: some View {
        BodySText(status.rawValue.capitalized)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor)
            .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch status {
        case .pending: return .orange
        case .completed: return .greenAccent
        case .failed: return .redAccent
        case .refunded: return .blueAccent
        }
    }
}

