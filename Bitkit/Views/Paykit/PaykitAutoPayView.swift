//
//  PaykitAutoPayView.swift
//  Bitkit
//
//  Auto-Pay settings view with notification preferences and confirmation toggles
//

import SwiftUI

struct PaykitAutoPayView: View {
    @StateObject private var viewModel = AutoPayViewModel()
    @EnvironmentObject private var app: AppViewModel
    @State private var showingAddPeerLimit = false
    @State private var showingAddRule = false
    @State private var selectedTab: AutoPayTab = .settings
    
    enum AutoPayTab: String, CaseIterable {
        case settings = "Settings"
        case limits = "Limits"
        case rules = "Rules"
        case history = "History"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Auto-Pay")
            
            // Tab Picker
            Picker("Tab", selection: $selectedTab) {
                ForEach(AutoPayTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedTab {
                    case .settings:
                        settingsTabContent
                    case .limits:
                        limitsTabContent
                    case .rules:
                        rulesTabContent
                    case .history:
                        historyTabContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadSettings()
            viewModel.loadHistory()
        }
        .sheet(isPresented: $showingAddPeerLimit) {
            AddPeerLimitView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingAddRule) {
            AddRuleView(viewModel: viewModel)
        }
    }
    
    // MARK: - Settings Tab
    
    private var settingsTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            enableSection
            
            if viewModel.settings.isEnabled {
                globalLimitSection
                notificationPreferencesSection
                confirmationSection
            }
        }
    }
    
    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(viewModel.settings.isEnabled ? Color.greenAccent.opacity(0.2) : Color.gray5)
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "bolt.fill")
                        .foregroundColor(viewModel.settings.isEnabled ? .greenAccent : .textSecondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    BodyLText("Auto-Pay")
                        .foregroundColor(.textPrimary)
                    
                    BodyMText(viewModel.settings.isEnabled ? "Automatically pay approved requests" : "All requests require manual approval")
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { viewModel.settings.isEnabled },
                    set: { newValue in
                        viewModel.settings.isEnabled = newValue
                        do {
                            try viewModel.saveSettings()
                        } catch {
                            app.toast(error)
                        }
                    }
                ))
                .labelsHidden()
            }
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(12)
        }
    }
    
    private var globalLimitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Spending Limits")
                .foregroundColor(.textSecondary)
            
            VStack(alignment: .leading, spacing: 16) {
                // Daily Limit
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        BodyMText("Daily Limit")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        BodyMBoldText(formatSats(viewModel.settings.globalDailyLimit))
                            .foregroundColor(.white)
                    }
                    
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.settings.globalDailyLimit) },
                            set: { newValue in
                                viewModel.settings.globalDailyLimit = Int64(newValue)
                                do {
                                    try viewModel.saveSettings()
                                } catch {
                                    app.toast(error)
                                }
                            }
                        ),
                        in: 1000...1000000,
                        step: 1000
                    )
                    .tint(.brandAccent)
                    
                    // Usage bar
                    HStack {
                        BodySText("Today: \(formatSats(viewModel.spentToday))")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        BodySText("Remaining: \(formatSats(viewModel.settings.globalDailyLimit - viewModel.spentToday))")
                            .foregroundColor(.greenAccent)
                    }
                }
                
                Divider()
                    .background(Color.white16)
                
                // Per-Payment Limit
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        BodyMText("Max Per Payment")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        BodyMBoldText(formatSats(viewModel.settings.maxPerPayment))
                            .foregroundColor(.white)
                    }
                    
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.settings.maxPerPayment) },
                            set: { newValue in
                                viewModel.settings.maxPerPayment = Int64(newValue)
                                do {
                                    try viewModel.saveSettings()
                                } catch {
                                    app.toast(error)
                                }
                            }
                        ),
                        in: 100...100000,
                        step: 100
                    )
                    .tint(.brandAccent)
                    
                    BodySText("Payments above this amount require manual approval")
                        .foregroundColor(.textSecondary)
                }
            }
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(12)
        }
    }
    
    private var notificationPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Notifications")
                .foregroundColor(.textSecondary)
            
            VStack(spacing: 0) {
                NotificationToggleRow(
                    title: "Payment Executed",
                    subtitle: "Notify when auto-pay completes a payment",
                    isOn: Binding(
                        get: { viewModel.settings.notifyOnPayment },
                        set: { newValue in
                            viewModel.settings.notifyOnPayment = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
                
                Divider().background(Color.white16)
                
                NotificationToggleRow(
                    title: "Limit Reached",
                    subtitle: "Notify when daily limit is reached",
                    isOn: Binding(
                        get: { viewModel.settings.notifyOnLimitReached },
                        set: { newValue in
                            viewModel.settings.notifyOnLimitReached = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
                
                Divider().background(Color.white16)
                
                NotificationToggleRow(
                    title: "Payment Blocked",
                    subtitle: "Notify when a payment is blocked by rules",
                    isOn: Binding(
                        get: { viewModel.settings.notifyOnBlocked },
                        set: { newValue in
                            viewModel.settings.notifyOnBlocked = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
                
                Divider().background(Color.white16)
                
                NotificationToggleRow(
                    title: "New Unknown Peer",
                    subtitle: "Notify when receiving requests from new peers",
                    isOn: Binding(
                        get: { viewModel.settings.notifyOnNewPeer },
                        set: { newValue in
                            viewModel.settings.notifyOnNewPeer = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
            }
            .background(Color.gray6)
            .cornerRadius(12)
        }
    }
    
    private var confirmationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Confirmation Requirements")
                .foregroundColor(.textSecondary)
            
            VStack(spacing: 0) {
                ConfirmationToggleRow(
                    title: "First Payment to Peer",
                    subtitle: "Require confirmation for first payment to any peer",
                    isOn: Binding(
                        get: { viewModel.settings.confirmFirstPayment },
                        set: { newValue in
                            viewModel.settings.confirmFirstPayment = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
                
                Divider().background(Color.white16)
                
                ConfirmationToggleRow(
                    title: "High-Value Payments",
                    subtitle: "Require confirmation above max per payment limit",
                    isOn: Binding(
                        get: { viewModel.settings.confirmHighValue },
                        set: { newValue in
                            viewModel.settings.confirmHighValue = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
                
                Divider().background(Color.white16)
                
                ConfirmationToggleRow(
                    title: "Subscriptions",
                    subtitle: "Require confirmation for subscription payments",
                    isOn: Binding(
                        get: { viewModel.settings.confirmSubscriptions },
                        set: { newValue in
                            viewModel.settings.confirmSubscriptions = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
                
                Divider().background(Color.white16)
                
                ConfirmationToggleRow(
                    title: "Biometric for Large Amounts",
                    subtitle: "Require Face ID/Touch ID for payments over 100k sats",
                    isOn: Binding(
                        get: { viewModel.settings.biometricForLarge },
                        set: { newValue in
                            viewModel.settings.biometricForLarge = newValue
                            do { try viewModel.saveSettings() } catch { app.toast(error) }
                        }
                    )
                )
            }
            .background(Color.gray6)
            .cornerRadius(12)
        }
    }
    
    // MARK: - Limits Tab
    
    private var limitsTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                BodyMBoldText("Per-Peer Limits")
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                Button {
                    showingAddPeerLimit = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        BodySText("Add Limit")
                    }
                    .foregroundColor(.brandAccent)
                }
            }
            
            if viewModel.peerLimits.isEmpty {
                emptyStateView(
                    icon: "person.2.circle",
                    title: "No Peer Limits",
                    message: "Set spending limits for specific peers"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.peerLimits) { limit in
                        PeerLimitRow(limit: limit, viewModel: viewModel)
                        
                        if limit.id != viewModel.peerLimits.last?.id {
                            Divider().background(Color.white16)
                        }
                    }
                }
                .background(Color.gray6)
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Rules Tab
    
    private var rulesTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                BodyMBoldText("Auto-Pay Rules")
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                Button {
                    showingAddRule = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        BodySText("Add Rule")
                    }
                    .foregroundColor(.brandAccent)
                }
            }
            
            if viewModel.rules.isEmpty {
                emptyStateView(
                    icon: "gearshape.2",
                    title: "No Rules",
                    message: "Create rules to automate payment decisions"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.rules) { rule in
                        RuleRow(rule: rule, viewModel: viewModel)
                        
                        if rule.id != viewModel.rules.last?.id {
                            Divider().background(Color.white16)
                        }
                    }
                }
                .background(Color.gray6)
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - History Tab
    
    private var historyTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            BodyMBoldText("Auto-Pay History")
                .foregroundColor(.textSecondary)
            
            if viewModel.history.isEmpty {
                emptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No History",
                    message: "Auto-pay transactions will appear here"
                )
            } else {
                ForEach(viewModel.history) { entry in
                    AutoPayHistoryRow(entry: entry)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.textSecondary)
            
            BodyLText(title)
                .foregroundColor(.textPrimary)
            
            BodyMText(message)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
}

// MARK: - Supporting Views

struct NotificationToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                BodyMText(title)
                    .foregroundColor(.white)
                BodySText(subtitle)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.brandAccent)
        }
        .padding(16)
    }
}

struct ConfirmationToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                BodyMText(title)
                    .foregroundColor(.white)
                BodySText(subtitle)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.orange)
        }
        .padding(16)
    }
}

struct AutoPayHistoryRow: View {
    let entry: AutoPayHistoryEntry
    
    var body: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(entry.wasApproved ? Color.greenAccent.opacity(0.2) : Color.redAccent.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: entry.wasApproved ? "checkmark" : "xmark")
                    .foregroundColor(entry.wasApproved ? .greenAccent : .redAccent)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                BodyMBoldText(entry.peerName)
                    .foregroundColor(.white)
                
                BodySText(entry.wasApproved ? "Auto-paid" : entry.reason)
                    .foregroundColor(.textSecondary)
                
                BodySText(formatDate(entry.timestamp))
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            BodyMText(entry.wasApproved ? "-\(formatSats(entry.amount))" : formatSats(entry.amount))
                .foregroundColor(entry.wasApproved ? .redAccent : .textSecondary)
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct PeerLimitRow: View {
    let limit: StoredPeerLimit
    @ObservedObject var viewModel: AutoPayViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                BodyMBoldText(limit.peerName)
                    .foregroundColor(.white)
                
                BodyMText("Limit: \(formatSats(limit.limitSats))")
                    .foregroundColor(.textSecondary)
                
                BodySText("Used: \(formatSats(limit.spentSats)) / \(formatSats(limit.limitSats))")
                    .foregroundColor(.textSecondary)
                
                ProgressView(value: limit.usagePercent, total: 100)
                    .tint(limit.usagePercent > 80 ? .redAccent : .brandAccent)
            }
            
            Spacer()
        }
        .padding(16)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                do {
                    try viewModel.deletePeerLimit(limit)
                } catch {
                    app.toast(error)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
}

struct RuleRow: View {
    let rule: StoredAutoPayRule
    @ObservedObject var viewModel: AutoPayViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BodyMBoldText(rule.name)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { _ in
                            var updated = rule
                            updated.isEnabled.toggle()
                            do {
                                try viewModel.addRule(updated)
                            } catch {
                                app.toast(error)
                            }
                        }
                    ))
                    .labelsHidden()
                }
                
                if let maxAmount = rule.maxAmountSats {
                    BodyMText("Max: \(formatSats(maxAmount))")
                        .foregroundColor(.textSecondary)
                }
                
                if !rule.allowedMethods.isEmpty {
                    BodySText("Methods: \(rule.allowedMethods.joined(separator: ", "))")
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .padding(16)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                do {
                    try viewModel.deleteRule(rule)
                } catch {
                    app.toast(error)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
}

struct AddPeerLimitView: View {
    @ObservedObject var viewModel: AutoPayViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel
    
    @State private var peerName = ""
    @State private var peerPubkey = ""
    @State private var limit: Int64 = 10000
    @State private var period = "daily"
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Peer Information")
                            .foregroundColor(.textPrimary)
                        
                        TextField("Peer Name", text: $peerName)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                        
                        TextField("Public Key (z-base32)", text: $peerPubkey)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Limit")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats", text: Binding(
                                get: { String(limit) },
                                set: { limit = Int64($0) ?? 0 }
                            ))
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .frame(width: 120)
                        }
                        
                        Picker("Period", selection: $period) {
                            Text("Daily").tag("daily")
                            Text("Weekly").tag("weekly")
                            Text("Monthly").tag("monthly")
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Button {
                        let peerLimit = StoredPeerLimit(
                            peerPubkey: peerPubkey,
                            peerName: peerName,
                            limitSats: limit,
                            period: period
                        )
                        
                        do {
                            try viewModel.addPeerLimit(peerLimit)
                            app.toast(type: .success, title: "Peer limit added")
                            dismiss()
                        } catch {
                            app.toast(error)
                        }
                    } label: {
                        BodyMText("Add Limit")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.brandAccent)
                            .cornerRadius(8)
                    }
                    .disabled(peerName.isEmpty || peerPubkey.isEmpty || limit <= 0)
                }
                .padding(16)
            }
            .navigationTitle("Add Peer Limit")
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

struct AddRuleView: View {
    @ObservedObject var viewModel: AutoPayViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel
    
    @State private var ruleName = ""
    @State private var maxAmount: Int64? = nil
    @State private var allowedMethods: [String] = []
    @State private var selectedMethod = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Rule Information")
                            .foregroundColor(.textPrimary)
                        
                        TextField("Rule Name", text: $ruleName)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Filters")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Max Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats (optional)", text: Binding(
                                get: { maxAmount.map { String($0) } ?? "" },
                                set: { maxAmount = Int64($0) }
                            ))
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .frame(width: 150)
                        }
                    }
                    
                    Button {
                        let rule = StoredAutoPayRule(
                            name: ruleName,
                            maxAmountSats: maxAmount,
                            allowedMethods: allowedMethods,
                            allowedPeers: []
                        )
                        
                        do {
                            try viewModel.addRule(rule)
                            app.toast(type: .success, title: "Rule added")
                            dismiss()
                        } catch {
                            app.toast(error)
                        }
                    } label: {
                        BodyMText("Add Rule")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.brandAccent)
                            .cornerRadius(8)
                    }
                    .disabled(ruleName.isEmpty)
                }
                .padding(16)
            }
            .navigationTitle("Add Auto-Pay Rule")
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

