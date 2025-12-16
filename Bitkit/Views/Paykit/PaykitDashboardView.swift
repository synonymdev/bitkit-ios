//
//  PaykitDashboardView.swift
//  Bitkit
//
//  Dashboard overview showing key metrics and Paykit features
//

import SwiftUI

struct PaykitDashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject private var navigation: NavigationViewModel
    @State private var showPubkyRingAuth = false
    
    private let pubkyRingBridge = PubkyRingBridge.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Paykit Dashboard")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Stats Section
                    statsSection
                    
                    // Quick Access Section
                    quickAccessSection
                    
                    // Payments Section
                    paymentsSection
                    
                    // Identity & Security Section
                    identitySection
                    
                    // Recent Activity
                    recentActivitySection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadDashboard()
        }
        .refreshable {
            viewModel.loadDashboard()
        }
        .sheet(isPresented: $showPubkyRingAuth) {
            PubkyRingAuthView { session in
                PaykitManager.shared.setSession(session)
                viewModel.loadDashboard()
            }
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
    
    private var paymentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Payments")
                .foregroundColor(.textSecondary)
            
            HStack(spacing: 12) {
                QuickAccessCard(
                    title: "Payment Requests",
                    icon: "arrow.down.doc.fill",
                    color: .green,
                    badge: viewModel.pendingRequests > 0 ? "\(viewModel.pendingRequests)" : nil
                ) {
                    navigation.navigate(.paykitPaymentRequests)
                }
                
                QuickAccessCard(
                    title: "Noise Payment",
                    icon: "waveform.circle.fill",
                    color: .purple,
                    badge: nil
                ) {
                    navigation.navigate(.paykitNoisePayment)
                }
            }
            
            HStack(spacing: 12) {
                QuickAccessCard(
                    title: "Contacts",
                    icon: "person.crop.circle.fill",
                    color: .cyan,
                    badge: viewModel.contactCount > 0 ? "\(viewModel.contactCount)" : nil
                ) {
                    navigation.navigate(.paykitContacts)
                }
                
                QuickAccessCard(
                    title: "Discover",
                    icon: "magnifyingglass.circle.fill",
                    color: .mint,
                    badge: nil
                ) {
                    navigation.navigate(.paykitContactDiscovery)
                }
            }
        }
    }
    
    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Identity & Security")
                .foregroundColor(.textSecondary)
            
            HStack(spacing: 12) {
                QuickAccessCard(
                    title: "Endpoints",
                    icon: "link.circle.fill",
                    color: .indigo,
                    badge: viewModel.publishedMethodsCount > 0 ? "\(viewModel.publishedMethodsCount)" : nil
                ) {
                    navigation.navigate(.paykitPrivateEndpoints)
                }
                
                QuickAccessCard(
                    title: "Key Rotation",
                    icon: "key.fill",
                    color: .yellow,
                    badge: nil
                ) {
                    navigation.navigate(.paykitRotationSettings)
                }
            }
            
            // Pubky-ring connection status
            pubkyRingConnectionCard
            
            // Session management
            QuickAccessCard(
                title: "Sessions",
                icon: "person.badge.shield.checkmark.fill",
                color: .teal,
                badge: viewModel.sessionCount > 0 ? "\(viewModel.sessionCount)" : nil
            ) {
                navigation.navigate(.paykitSessionManagement)
            }
        }
    }
    
    private var pubkyRingConnectionCard: some View {
        Button {
            showPubkyRingAuth = true
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(pubkyRingBridge.isPubkyRingInstalled ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: pubkyRingBridge.isPubkyRingInstalled ? "checkmark.shield.fill" : "qrcode")
                        .foregroundColor(pubkyRingBridge.isPubkyRingInstalled ? .green : .orange)
                        .font(.title3)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    BodyMBoldText(pubkyRingBridge.isPubkyRingInstalled ? "Pubky-ring Connected" : "Connect Pubky-ring")
                        .foregroundColor(.white)
                    
                    BodySText(pubkyRingBridge.authenticationStatus.description)
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.textSecondary)
                    .font(.caption)
            }
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(12)
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
                // Simple empty state instead of the large overlay
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.textSecondary)
                    
                    BodyMText("No recent activity")
                        .foregroundColor(.textSecondary)
                    
                    BodySText("Your Paykit transactions will appear here")
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color.gray6)
                .cornerRadius(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentReceipts) { receipt in
                        DashboardReceiptRow(receipt: receipt)
                        
                        if receipt.id != viewModel.recentReceipts.last?.id {
                            Divider()
                                .background(Color.white16)
                        }
                    }
                }
                .background(Color.gray6)
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
        .background(Color.gray6)
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
            .background(Color.gray6)
            .cornerRadius(8)
        }
    }
}

struct DashboardReceiptRow: View {
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

