//
//  PaykitAutoPayView.swift
//  Bitkit
//
//  Auto-Pay settings view
//

import SwiftUI

struct PaykitAutoPayView: View {
    @StateObject private var viewModel = AutoPayViewModel()
    @EnvironmentObject private var app: AppViewModel
    @State private var showingAddPeerLimit = false
    @State private var showingAddRule = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Auto-Pay")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Enable/Disable Toggle
                    enableSection
                    
                    if viewModel.settings.isEnabled {
                        // Global Daily Limit
                        globalLimitSection
                        
                        // Per-Peer Limits
                        peerLimitsSection
                        
                        // Auto-Pay Rules
                        rulesSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadSettings()
        }
        .sheet(isPresented: $showingAddPeerLimit) {
            AddPeerLimitView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingAddRule) {
            AddRuleView(viewModel: viewModel)
        }
    }
    
    private var enableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    BodyLText("Auto-Pay")
                        .foregroundColor(.textPrimary)
                    
                    BodyMText(viewModel.settings.isEnabled ? "Enabled" : "Disabled")
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
            .background(Color.gray900)
            .cornerRadius(8)
        }
    }
    
    private var globalLimitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyLText("Global Daily Limit")
                .foregroundColor(.textPrimary)
            
            VStack(alignment: .leading, spacing: 12) {
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
            }
            .padding(16)
            .background(Color.gray900)
            .cornerRadius(8)
        }
    }
    
    private var peerLimitsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyLText("Per-Peer Limits")
                    .foregroundColor(.textPrimary)
                
                Spacer()
                
                Button {
                    showingAddPeerLimit = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.brandAccent)
                        .font(.title3)
                }
            }
            
            if viewModel.peerLimits.isEmpty {
                BodyMText("No peer limits set")
                    .foregroundColor(.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray900)
                    .cornerRadius(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.peerLimits) { limit in
                        PeerLimitRow(limit: limit, viewModel: viewModel)
                        
                        if limit.id != viewModel.peerLimits.last?.id {
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
    
    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyLText("Auto-Pay Rules")
                    .foregroundColor(.textPrimary)
                
                Spacer()
                
                Button {
                    showingAddRule = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.brandAccent)
                        .font(.title3)
                }
            }
            
            if viewModel.rules.isEmpty {
                BodyMText("No rules set")
                    .foregroundColor(.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.gray900)
                    .cornerRadius(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.rules) { rule in
                        RuleRow(rule: rule, viewModel: viewModel)
                        
                        if rule.id != viewModel.rules.last?.id {
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
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
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
                            .background(Color.gray900)
                            .cornerRadius(8)
                        
                        TextField("Public Key (z-base32)", text: $peerPubkey)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .padding(12)
                            .background(Color.gray900)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Limit")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats", value: $limit, format: .number)
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray900)
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
                            .background(Color.gray900)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Filters")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Max Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats (optional)", value: $maxAmount, format: .number)
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray900)
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

