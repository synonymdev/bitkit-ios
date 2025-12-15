//
//  PaykitDashboardView.swift
//  Bitkit
//
//  Dashboard overview showing key metrics and recent activity
//

import SwiftUI

struct PaykitDashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var navigation: NavigationViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Paykit Dashboard")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Stats Section
                    statsSection
                    
                    // Quick Access Section
                    quickAccessSection
                    
                    // Recent Activity
                    recentActivitySection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadDashboard()
        }
        .refreshable {
            viewModel.loadDashboard()
        }
    }
    
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Overview")
                .foregroundColor(.textSecondary)
            
            HStack(spacing: 12) {
                StatCard(
                    title: "Total Sent",
                    value: formatSats(viewModel.totalSent),
                    icon: "arrow.up.circle.fill",
                    color: .red
                )
                
                StatCard(
                    title: "Total Received",
                    value: formatSats(viewModel.totalReceived),
                    icon: "arrow.down.circle.fill",
                    color: .green
                )
            }
            
            HStack(spacing: 12) {
                StatCard(
                    title: "Contacts",
                    value: "\(viewModel.contactCount)",
                    icon: "person.2.fill",
                    color: .blue
                )
                
                StatCard(
                    title: "Pending",
                    value: "\(viewModel.pendingCount)",
                    icon: "clock.fill",
                    color: .orange
                )
            }
        }
    }
    
    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Quick Access")
                .foregroundColor(.textSecondary)
            
            HStack(spacing: 12) {
                QuickAccessCard(
                    title: "Auto-Pay",
                    icon: "arrow.clockwise.circle.fill",
                    color: .orange,
                    badge: viewModel.autoPayEnabled ? "ON" : nil
                ) {
                    navigation.navigate(.paykitAutoPay)
                }
                
                QuickAccessCard(
                    title: "Subscriptions",
                    icon: "repeat.circle.fill",
                    color: .blue,
                    badge: viewModel.activeSubscriptions > 0 ? "\(viewModel.activeSubscriptions)" : nil
                ) {
                    navigation.navigate(.paykitSubscriptions)
                }
            }
        }
    }
    
    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyLText("Recent Activity")
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                NavigationLink(value: Route.paykitReceipts) {
                    BodySText("See All")
                        .foregroundColor(.brandAccent)
                }
            }
            
            if viewModel.recentReceipts.isEmpty {
                EmptyStateView(
                    type: .home,
                    onClose: nil
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentReceipts) { receipt in
                        ReceiptRow(receipt: receipt)
                        
                        if receipt.id != viewModel.recentReceipts.last?.id {
                            Divider()
                                .background(Color.white16)
                        }
                    }
                }
                .background(Color.gray900)
                .cornerRadius(8)
            }
        }
    }
    
    private func formatSats(_ amount: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
            
            BodyMBoldText(value)
                .foregroundColor(.white)
            
            BodySText(title)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray900)
        .cornerRadius(8)
    }
}

struct QuickAccessCard: View {
    let title: String
    let icon: String
    let color: Color
    let badge: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.title3)
                    Spacer()
                    if let badge = badge {
                        Text(badge)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color)
                            .cornerRadius(8)
                    }
                }
                
                BodySText(title)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Color.gray900)
            .cornerRadius(8)
        }
    }
}

struct ReceiptRow: View {
    let receipt: PaymentReceipt
    
    var body: some View {
        HStack {
            Image(systemName: receipt.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundColor(receipt.direction == .sent ? .red : .green)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                BodyMText(receipt.displayName)
                    .foregroundColor(.white)
                
                BodySText(receipt.paymentMethod)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                BodyMText(receipt.formattedAmount)
                    .foregroundColor(receipt.direction == .sent ? .red : .green)
                
                BodySText(receipt.status.rawValue.capitalized)
                    .foregroundColor(statusColor(receipt.status))
            }
        }
        .padding(16)
    }
    
    private func statusColor(_ status: PaymentReceiptStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .completed: return .green
        case .failed: return .red
        case .refunded: return .purple
        }
    }
}

