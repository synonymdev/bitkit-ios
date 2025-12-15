//
//  PaykitReceiptsView.swift
//  Bitkit
//
//  Receipt history view with search and filtering
//

import SwiftUI

struct PaykitReceiptsView: View {
    @StateObject private var viewModel = ReceiptsViewModel()
    @State private var showingFilters = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Receipts")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Stats Section
                    statsSection
                    
                    // Search and Filters
                    searchAndFiltersSection
                    
                    // Receipts List
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if viewModel.receipts.isEmpty {
                        emptyStateView
                    } else {
                        receiptsList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadReceipts()
        }
        .refreshable {
            viewModel.loadReceipts()
        }
    }
    
    private var statsSection: some View {
        HStack(spacing: 12) {
            StatBox(
                title: "Total Sent",
                value: formatSats(viewModel.totalSent),
                color: .redAccent
            )
            
            StatBox(
                title: "Total Received",
                value: formatSats(viewModel.totalReceived),
                color: .greenAccent
            )
        }
    }
    
    private var searchAndFiltersSection: some View {
        VStack(spacing: 12) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textSecondary)
                
                TextField("Search receipts", text: $viewModel.searchQuery)
                    .foregroundColor(.white)
                    .onChange(of: viewModel.searchQuery) { _ in
                        viewModel.filterReceipts()
                    }
            }
            .padding(12)
            .background(Color.gray900)
            .cornerRadius(8)
            
            // Filter chips
            if viewModel.selectedStatus != nil || viewModel.selectedDirection != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let status = viewModel.selectedStatus {
                            FilterChip(
                                title: status.rawValue.capitalized,
                                onRemove: {
                                    viewModel.selectedStatus = nil
                                    viewModel.filterReceipts()
                                }
                            )
                        }
                        
                        if let direction = viewModel.selectedDirection {
                            FilterChip(
                                title: direction.rawValue.capitalized,
                                onRemove: {
                                    viewModel.selectedDirection = nil
                                    viewModel.filterReceipts()
                                }
                            )
                        }
                        
                        Button {
                            viewModel.clearFilters()
                        } label: {
                            BodySText("Clear All")
                                .foregroundColor(.brandAccent)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            
            // Filter button
            Button {
                showingFilters = true
            } label: {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.brandAccent)
                    BodySText("Filters")
                        .foregroundColor(.brandAccent)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.gray900)
                .cornerRadius(8)
            }
        }
    }
    
    private var receiptsList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.receipts) { receipt in
                ReceiptRow(receipt: receipt)
                
                if receipt.id != viewModel.receipts.last?.id {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray900)
        .cornerRadius(8)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.text")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Receipts")
                .foregroundColor(.textPrimary)
            
            BodyMText("Your payment history will appear here")
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private func formatSats(_ amount: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BodySText(title)
                .foregroundColor(.textSecondary)
            
            BodyMBoldText(value)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray900)
        .cornerRadius(8)
    }
}

struct FilterChip: View {
    let title: String
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            BodySText(title)
                .foregroundColor(.white)
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.textSecondary)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.brandAccent.opacity(0.2))
        .cornerRadius(16)
    }
}

struct ReceiptRow: View {
    let receipt: PaymentReceipt
    
    var body: some View {
        NavigationLink(value: Route.paykitReceiptDetail(receipt)) {
            HStack {
                Image(systemName: receipt.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(receipt.direction == .sent ? .redAccent : .greenAccent)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 4) {
                    BodyMText(receipt.displayName)
                        .foregroundColor(.white)
                    
                    HStack(spacing: 8) {
                        BodySText(receipt.paymentMethod)
                            .foregroundColor(.textSecondary)
                        
                        if receipt.status == .pending {
                            BodySText("• Pending")
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    BodyMBoldText(receipt.formattedAmount)
                        .foregroundColor(receipt.direction == .sent ? .redAccent : .greenAccent)
                    
                    BodySText(formatDate(receipt.createdAt))
                        .foregroundColor(.textSecondary)
                }
            }
            .padding(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

