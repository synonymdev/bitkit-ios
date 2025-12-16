//
//  PaykitSubscriptionsView.swift
//  Bitkit
//
//  Subscriptions management view with proposals, payment history, and spending limits
//

import SwiftUI

struct PaykitSubscriptionsView: View {
    @StateObject private var viewModel = SubscriptionsViewModel()
    @EnvironmentObject private var app: AppViewModel
    @State private var selectedTab: SubscriptionTab = .active
    @State private var selectedSubscription: BitkitSubscription? = nil
    @State private var showingDetail = false
    
    enum SubscriptionTab: String, CaseIterable {
        case active = "Active"
        case proposals = "Proposals"
        case history = "History"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Subscriptions",
                trailing: AnyView(
                    Button {
                        viewModel.showingAddSubscription = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.brandAccent)
                    }
                )
            )
            
            // Tab Picker
            Picker("Tab", selection: $selectedTab) {
                ForEach(SubscriptionTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        switch selectedTab {
                        case .active:
                            activeSubscriptionsSection
                        case .proposals:
                            proposalsSection
                        case .history:
                            paymentHistorySection
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadSubscriptions()
            viewModel.loadProposals()
            viewModel.loadPaymentHistory()
        }
        .refreshable {
            viewModel.loadSubscriptions()
            viewModel.loadProposals()
            viewModel.loadPaymentHistory()
        }
        .sheet(isPresented: $viewModel.showingAddSubscription) {
            AddSubscriptionView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingDetail) {
            if let subscription = selectedSubscription {
                SubscriptionDetailSheet(subscription: subscription, viewModel: viewModel)
            }
        }
    }
    
    // MARK: - Active Subscriptions
    
    private var activeSubscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Spending Limits Summary
            spendingLimitsSummary
            
            // Subscriptions List
            if viewModel.subscriptions.isEmpty {
                emptyStateView
            } else {
                subscriptionsList
            }
        }
    }
    
    private var spendingLimitsSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyMBoldText("Monthly Spending Limits")
                    .foregroundColor(.textSecondary)
                Spacer()
                Button {
                    // Navigate to spending limits settings
                } label: {
                    BodySText("Manage")
                        .foregroundColor(.brandAccent)
                }
            }
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    BodySText("Used")
                        .foregroundColor(.textSecondary)
                    HeadlineMText(formatSats(viewModel.totalSpentThisMonth))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    BodySText("Remaining")
                        .foregroundColor(.textSecondary)
                    HeadlineMText(formatSats(viewModel.remainingSpendingLimit))
                        .foregroundColor(.greenAccent)
                }
            }
            
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray5)
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(spendingPercentage > 0.8 ? Color.orange : Color.brandAccent)
                        .frame(width: geo.size.width * spendingPercentage, height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var spendingPercentage: CGFloat {
        guard viewModel.monthlySpendingLimit > 0 else { return 0 }
        return min(1.0, CGFloat(viewModel.totalSpentThisMonth) / CGFloat(viewModel.monthlySpendingLimit))
    }
    
    private var subscriptionsList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.subscriptions) { subscription in
                Button {
                    selectedSubscription = subscription
                    showingDetail = true
                } label: {
                    SubscriptionRow(subscription: subscription, viewModel: viewModel)
                }
                .buttonStyle(.plain)
                
                if subscription.id != viewModel.subscriptions.last?.id {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray6)
        .cornerRadius(8)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "repeat.circle")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Active Subscriptions")
                .foregroundColor(.textPrimary)
            
            BodyMText("Create recurring payments to providers")
                .foregroundColor(.textSecondary)
            
            Button {
                viewModel.showingAddSubscription = true
            } label: {
                BodyMText("Add Subscription")
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.brandAccent)
                    .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - Proposals Section
    
    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.proposals.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 80))
                        .foregroundColor(.textSecondary)
                    
                    BodyLText("No Proposals")
                        .foregroundColor(.textPrimary)
                    
                    BodyMText("Subscription proposals from providers will appear here")
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(viewModel.proposals) { proposal in
                    ProposalCard(proposal: proposal, viewModel: viewModel)
                }
            }
        }
    }
    
    // MARK: - Payment History Section
    
    private var paymentHistorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.paymentHistory.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 80))
                        .foregroundColor(.textSecondary)
                    
                    BodyLText("No Payment History")
                        .foregroundColor(.textPrimary)
                    
                    BodyMText("Subscription payments will be recorded here")
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(viewModel.paymentHistory) { payment in
                    PaymentHistoryRow(payment: payment)
                }
            }
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
}

// MARK: - Proposal Card

struct ProposalCard: View {
    let proposal: SubscriptionProposal
    @ObservedObject var viewModel: SubscriptionsViewModel
    @EnvironmentObject private var app: AppViewModel
    @State private var isAccepting = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.2))
                        .frame(width: 48, height: 48)
                    
                    Text(String(proposal.providerName.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(.brandAccent)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    BodyMBoldText(proposal.providerName)
                        .foregroundColor(.white)
                    
                    BodySText(truncatePubkey(proposal.providerPubkey))
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    HeadlineMText(formatSats(proposal.amountSats))
                        .foregroundColor(.white)
                    BodySText("/ \(proposal.frequency)")
                        .foregroundColor(.textSecondary)
                }
            }
            
            if !proposal.description.isEmpty {
                BodyMText(proposal.description)
                    .foregroundColor(.textSecondary)
            }
            
            // Terms summary
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    BodySText("Method")
                        .foregroundColor(.textSecondary)
                    BodySText(proposal.methodId.capitalized)
                        .foregroundColor(.white)
                }
                
                if let maxPayments = proposal.maxPayments {
                    VStack(alignment: .leading, spacing: 2) {
                        BodySText("Max Payments")
                            .foregroundColor(.textSecondary)
                        BodySText("\(maxPayments)")
                            .foregroundColor(.white)
                    }
                }
                
                if let startDate = proposal.startDate {
                    VStack(alignment: .leading, spacing: 2) {
                        BodySText("Starts")
                            .foregroundColor(.textSecondary)
                        BodySText(formatDate(startDate))
                            .foregroundColor(.white)
                    }
                }
            }
            
            HStack(spacing: 12) {
                Button {
                    declineProposal()
                } label: {
                    BodyMText("Decline")
                        .foregroundColor(.redAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.redAccent.opacity(0.2))
                        .cornerRadius(8)
                }
                
                Button {
                    acceptProposal()
                } label: {
                    HStack {
                        if isAccepting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        BodyMText("Accept")
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.greenAccent)
                    .cornerRadius(8)
                }
                .disabled(isAccepting)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private func acceptProposal() {
        isAccepting = true
        Task {
            defer { isAccepting = false }
            do {
                try viewModel.acceptProposal(proposal)
                app.toast(type: .success, title: "Subscription created!")
            } catch {
                app.toast(error)
            }
        }
    }
    
    private func declineProposal() {
        do {
            try viewModel.declineProposal(proposal)
            app.toast(type: .success, title: "Proposal declined")
        } catch {
            app.toast(error)
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)")"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
    
    private func truncatePubkey(_ pubkey: String) -> String {
        guard pubkey.count > 16 else { return pubkey }
        return "\(pubkey.prefix(8))...\(pubkey.suffix(8))"
    }
}

// MARK: - Payment History Row

struct PaymentHistoryRow: View {
    let payment: SubscriptionPayment
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                BodyMBoldText(payment.subscriptionName)
                    .foregroundColor(.white)
                
                BodySText(formatDate(payment.paidAt))
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                BodyMText("-\(formatSats(payment.amountSats))")
                    .foregroundColor(.redAccent)
                
                PaymentStatusBadge(status: payment.status)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(8)
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct PaymentStatusBadge: View {
    let status: SubscriptionPaymentStatus
    
    var body: some View {
        BodySText(status.rawValue)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor)
            .cornerRadius(4)
    }
    
    private var statusColor: Color {
        switch status {
        case .completed: return .greenAccent
        case .pending: return .orange
        case .failed: return .redAccent
        }
    }
}

// MARK: - Subscription Detail Sheet

struct SubscriptionDetailSheet: View {
    let subscription: BitkitSubscription
    @ObservedObject var viewModel: SubscriptionsViewModel
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingSpendingLimit = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    detailsSection
                    spendingLimitSection
                    paymentsSection
                    actionsSection
                }
                .padding(20)
            }
            .background(Color.gray5)
            .navigationTitle("Subscription Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSpendingLimit) {
            EditSpendingLimitSheet(subscription: subscription, viewModel: viewModel)
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(subscription.isActive ? Color.greenAccent.opacity(0.2) : Color.gray5)
                    .frame(width: 72, height: 72)
                
                Text(String(subscription.providerName.prefix(1)).uppercased())
                    .font(.largeTitle)
                    .foregroundColor(subscription.isActive ? .greenAccent : .textSecondary)
            }
            
            HeadlineLText(subscription.providerName)
                .foregroundColor(.white)
            
            HStack(spacing: 4) {
                BodyMText(subscription.isActive ? "Active" : "Paused")
                    .foregroundColor(subscription.isActive ? .greenAccent : .orange)
                BodyMText("•")
                    .foregroundColor(.textSecondary)
                BodyMText("\(formatSats(subscription.amountSats)) / \(subscription.frequency)")
                    .foregroundColor(.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Details")
                .foregroundColor(.textSecondary)
            
            DetailRow(label: "Payment Method", value: subscription.methodId.capitalized)
            DetailRow(label: "Total Payments", value: "\(subscription.paymentCount)")
            DetailRow(label: "Total Spent", value: formatSats(subscription.totalSpent))
            
            if let nextPayment = subscription.nextPaymentAt {
                DetailRow(label: "Next Payment", value: formatDate(nextPayment))
            }
            
            DetailRow(label: "Created", value: formatDate(subscription.createdAt))
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var spendingLimitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyMBoldText("Spending Limit")
                    .foregroundColor(.textSecondary)
                Spacer()
                Button {
                    showingSpendingLimit = true
                } label: {
                    BodySText("Edit")
                        .foregroundColor(.brandAccent)
                }
            }
            
            if let limit = subscription.spendingLimit {
                HStack {
                    BodyMText("Max per \(limit.period.rawValue)")
                        .foregroundColor(.white)
                    Spacer()
                    BodyMBoldText(formatSats(limit.maxAmount))
                        .foregroundColor(.white)
                }
                
                // Progress bar
                let usedPercent = min(1.0, Double(limit.usedAmount) / Double(limit.maxAmount))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray5)
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(usedPercent > 0.8 ? Color.orange : Color.brandAccent)
                            .frame(width: geo.size.width * usedPercent, height: 8)
                    }
                }
                .frame(height: 8)
                
                BodySText("\(formatSats(limit.usedAmount)) used of \(formatSats(limit.maxAmount))")
                    .foregroundColor(.textSecondary)
            } else {
                Button {
                    showingSpendingLimit = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        BodyMText("Set Spending Limit")
                    }
                    .foregroundColor(.brandAccent)
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var paymentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Recent Payments")
                .foregroundColor(.textSecondary)
            
            let recentPayments = viewModel.paymentHistory.filter { $0.subscriptionId == subscription.id }.prefix(5)
            
            if recentPayments.isEmpty {
                BodyMText("No payments yet")
                    .foregroundColor(.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(recentPayments)) { payment in
                    HStack {
                        BodySText(formatDate(payment.paidAt))
                            .foregroundColor(.textSecondary)
                        Spacer()
                        BodySText(formatSats(payment.amountSats))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button {
                do {
                    try viewModel.toggleActive(subscription)
                    app.toast(type: .success, title: subscription.isActive ? "Subscription paused" : "Subscription resumed")
                } catch {
                    app.toast(error)
                }
            } label: {
                HStack {
                    Image(systemName: subscription.isActive ? "pause.circle" : "play.circle")
                    BodyMText(subscription.isActive ? "Pause Subscription" : "Resume Subscription")
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.brandAccent)
                .cornerRadius(12)
            }
            
            Button {
                do {
                    try viewModel.deleteSubscription(subscription)
                    app.toast(type: .success, title: "Subscription cancelled")
                    dismiss()
                } catch {
                    app.toast(error)
                }
            } label: {
                HStack {
                    Image(systemName: "trash")
                    BodyMText("Cancel Subscription")
                }
                .foregroundColor(.redAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.redAccent.opacity(0.2))
                .cornerRadius(12)
            }
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
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
            BodySText(label)
                .foregroundColor(.textSecondary)
            Spacer()
            BodySText(value)
                .foregroundColor(.white)
        }
    }
}

// MARK: - Edit Spending Limit Sheet

struct EditSpendingLimitSheet: View {
    let subscription: BitkitSubscription
    @ObservedObject var viewModel: SubscriptionsViewModel
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var maxAmount: Int64 = 100000
    @State private var period: SpendingLimitPeriod = .monthly
    @State private var requireConfirmation = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Maximum Amount")
                            .foregroundColor(.textPrimary)
                        
                        TextField("sats", value: $maxAmount, format: .number)
                            .foregroundColor(.white)
                            .keyboardType(.numberPad)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Period")
                            .foregroundColor(.textPrimary)
                        
                        Picker("Period", selection: $period) {
                            Text("Daily").tag(SpendingLimitPeriod.daily)
                            Text("Weekly").tag(SpendingLimitPeriod.weekly)
                            Text("Monthly").tag(SpendingLimitPeriod.monthly)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Toggle(isOn: $requireConfirmation) {
                        VStack(alignment: .leading, spacing: 4) {
                            BodyMText("Require Confirmation")
                                .foregroundColor(.white)
                            BodySText("Ask for approval before each payment")
                                .foregroundColor(.textSecondary)
                        }
                    }
                    .tint(.brandAccent)
                    
                    Button {
                        saveLimit()
                    } label: {
                        BodyMText("Save Limit")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.brandAccent)
                            .cornerRadius(8)
                    }
                    .disabled(maxAmount <= 0)
                    
                    if subscription.spendingLimit != nil {
                        Button {
                            removeLimit()
                        } label: {
                            BodyMText("Remove Limit")
                                .foregroundColor(.redAccent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Spending Limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if let existing = subscription.spendingLimit {
                maxAmount = existing.maxAmount
                period = existing.period
                requireConfirmation = existing.requireConfirmation
            }
        }
    }
    
    private func saveLimit() {
        let limit = SubscriptionSpendingLimit(
            maxAmount: maxAmount,
            period: period,
            usedAmount: subscription.spendingLimit?.usedAmount ?? 0,
            requireConfirmation: requireConfirmation
        )
        
        do {
            try viewModel.updateSpendingLimit(subscription, limit: limit)
            app.toast(type: .success, title: "Spending limit saved")
            dismiss()
        } catch {
            app.toast(error)
        }
    }
    
    private func removeLimit() {
        do {
            try viewModel.updateSpendingLimit(subscription, limit: nil)
            app.toast(type: .success, title: "Spending limit removed")
            dismiss()
        } catch {
            app.toast(error)
        }
    }
}

struct SubscriptionRow: View {
    let subscription: BitkitSubscription
    @ObservedObject var viewModel: SubscriptionsViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            // Provider avatar
            ZStack {
                Circle()
                    .fill(subscription.isActive ? Color.brandAccent.opacity(0.2) : Color.gray5)
                    .frame(width: 44, height: 44)
                
                Text(String(subscription.providerName.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundColor(subscription.isActive ? .brandAccent : .textSecondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    BodyMBoldText(subscription.providerName)
                        .foregroundColor(.white)
                    
                    if !subscription.isActive {
                        BodySText("Paused")
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                
                BodyMText("\(formatSats(subscription.amountSats)) / \(subscription.frequency)")
                    .foregroundColor(.textSecondary)
                
                HStack(spacing: 8) {
                    if subscription.paymentCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                            BodySText("\(subscription.paymentCount)")
                        }
                        .foregroundColor(.greenAccent)
                    }
                    
                    if let nextPayment = subscription.nextPaymentAt, subscription.isActive {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            BodySText(formatDate(nextPayment))
                        }
                        .foregroundColor(.textSecondary)
                    }
                    
                    if let limit = subscription.spendingLimit {
                        HStack(spacing: 2) {
                            Image(systemName: "shield.fill")
                                .font(.caption2)
                            BodySText("\(formatSats(limit.usedAmount))/\(formatSats(limit.maxAmount))")
                        }
                        .foregroundColor(.brandAccent)
                    }
                }
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { subscription.isActive },
                set: { _ in
                    do {
                        try viewModel.toggleActive(subscription)
                    } catch {
                        app.toast(error)
                    }
                }
            ))
            .labelsHidden()
        }
        .padding(16)
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)")"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct AddSubscriptionView: View {
    @ObservedObject var viewModel: SubscriptionsViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel
    
    @State private var providerName = ""
    @State private var providerPubkey = ""
    @State private var amount: Int64 = 1000
    @State private var frequency = "monthly"
    @State private var methodId = "lightning"
    @State private var description = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Provider Information")
                            .foregroundColor(.textPrimary)
                        
                        TextField("Provider Name", text: $providerName)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                        
                        TextField("Provider Public Key (z-base32)", text: $providerPubkey)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Payment Details")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats", text: Binding(
                                get: { String(amount) },
                                set: { amount = Int64($0) ?? 0 }
                            ))
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .frame(width: 120)
                        }
                        
                        Picker("Frequency", selection: $frequency) {
                            Text("Daily").tag("daily")
                            Text("Weekly").tag("weekly")
                            Text("Monthly").tag("monthly")
                            Text("Yearly").tag("yearly")
                        }
                        .pickerStyle(.segmented)
                        
                        Picker("Payment Method", selection: $methodId) {
                            Text("Lightning").tag("lightning")
                            Text("On-Chain").tag("onchain")
                        }
                        .pickerStyle(.segmented)
                        
                        TextField("Description (optional)", text: $description)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                    }
                    
                    Button {
                        let subscription = BitkitSubscription(
                            providerName: providerName,
                            providerPubkey: providerPubkey,
                            amountSats: amount,
                            currency: "SAT",
                            frequency: frequency,
                            description: description,
                            methodId: methodId
                        )
                        
                        do {
                            try viewModel.addSubscription(subscription)
                            app.toast(type: .success, title: "Subscription created")
                            dismiss()
                        } catch {
                            app.toast(error)
                        }
                    } label: {
                        BodyMText("Create Subscription")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.brandAccent)
                            .cornerRadius(8)
                    }
                    .disabled(providerName.isEmpty || providerPubkey.isEmpty || amount <= 0)
                }
                .padding(16)
            }
            .navigationTitle("Add Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

