//
//  PaykitSubscriptionsView.swift
//  Bitkit
//
//  Subscriptions management view
//

import SwiftUI

struct PaykitSubscriptionsView: View {
    @StateObject private var viewModel = SubscriptionsViewModel()
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Subscriptions")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if viewModel.subscriptions.isEmpty {
                        emptyStateView
                    } else {
                        subscriptionsList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadSubscriptions()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    viewModel.showingAddSubscription = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.brandAccent)
                }
            }
        }
        .sheet(isPresented: $viewModel.showingAddSubscription) {
            AddSubscriptionView(viewModel: viewModel)
        }
    }
    
    private var subscriptionsList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.subscriptions) { subscription in
                SubscriptionRow(subscription: subscription, viewModel: viewModel)
                
                if subscription.id != viewModel.subscriptions.last?.id {
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
            Image(systemName: "repeat.circle")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Subscriptions")
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
}

struct SubscriptionRow: View {
    let subscription: Subscription
    @ObservedObject var viewModel: SubscriptionsViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BodyMBoldText(subscription.providerName)
                        .foregroundColor(.white)
                    
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
                
                BodyMText("\(formatSats(subscription.amountSats)) / \(subscription.frequency)")
                    .foregroundColor(.textSecondary)
                
                if !subscription.description.isEmpty {
                    BodySText(subscription.description)
                        .foregroundColor(.textSecondary)
                }
                
                if subscription.paymentCount > 0 {
                    BodySText("\(subscription.paymentCount) payment\(subscription.paymentCount == 1 ? "" : "s")")
                        .foregroundColor(.textSecondary)
                }
                
                if let nextPayment = subscription.nextPaymentAt {
                    BodySText("Next: \(formatDate(nextPayment))")
                        .foregroundColor(.textSecondary)
                }
            }
        }
        .padding(16)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                do {
                    try viewModel.deleteSubscription(subscription)
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
                            .background(Color.gray900)
                            .cornerRadius(8)
                        
                        TextField("Provider Public Key (z-base32)", text: $providerPubkey)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .padding(12)
                            .background(Color.gray900)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Payment Details")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats", value: $amount, format: .number)
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray900)
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
                            .background(Color.gray900)
                            .cornerRadius(8)
                    }
                    
                    Button {
                        let subscription = Subscription(
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

