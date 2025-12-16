//
//  NoisePaymentView.swift
//  Bitkit
//
//  Noise payment send/receive view with real Pubky-ring integration
//

import SwiftUI

struct NoisePaymentView: View {
    @StateObject private var viewModel = NoisePaymentViewModel()
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @State private var mode: PaymentMode = .send
    @State private var recipientPubkey = ""
    @State private var amount: Int64 = 1000
    @State private var methodId = "lightning"
    @State private var description = ""
    @State private var showingContactPicker = false
    @State private var showingPubkyRingAuth = false
    
    enum PaymentMode: String, CaseIterable {
        case send = "Send"
        case receive = "Receive"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Noise Payment")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Session Status Card
                    sessionStatusCard
                    
                    // Mode Selector
                    modeSelector
                    
                    if mode == .send {
                        sendPaymentForm
                    } else {
                        receivePaymentSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.checkSessionStatus()
        }
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerSheet { contact in
                recipientPubkey = contact.pubkey
            }
        }
        .sheet(isPresented: $showingPubkyRingAuth) {
            PubkyRingAuthView { session in
                viewModel.handleSessionAuthenticated(session)
            }
        }
    }
    
    // MARK: - Session Status Card
    
    private var sessionStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(viewModel.isSessionActive ? Color.greenAccent.opacity(0.2) : Color.orange.opacity(0.2))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: viewModel.isSessionActive ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundColor(viewModel.isSessionActive ? .greenAccent : .orange)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    BodyMBoldText(viewModel.isSessionActive ? "Connected to Pubky-ring" : "Not Connected")
                        .foregroundColor(.white)
                    
                    if viewModel.isSessionActive, let pubkey = viewModel.currentUserPubkey {
                        BodySText(truncatePubkey(pubkey))
                            .foregroundColor(.textSecondary)
                    } else {
                        BodySText("Authenticate to send Noise payments")
                            .foregroundColor(.textSecondary)
                    }
                }
                
                Spacer()
                
                if viewModel.isSessionActive {
                    Button {
                        viewModel.refreshSession()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.brandAccent)
                    }
                } else {
                    Button {
                        showingPubkyRingAuth = true
                    } label: {
                        BodySText("Connect")
                            .foregroundColor(.brandAccent)
                    }
                }
            }
            
            // Noise key info
            if viewModel.isSessionActive {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        BodySText("Noise Key")
                            .foregroundColor(.textSecondary)
                        BodySText(viewModel.noiseKeyStatus)
                            .foregroundColor(viewModel.hasNoiseKey ? .greenAccent : .orange)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        BodySText("Channels")
                            .foregroundColor(.textSecondary)
                        BodySText(viewModel.activeChannelsStatus)
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var modeSelector: some View {
        Picker("Mode", selection: $mode) {
            ForEach(PaymentMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }
    
    // MARK: - Send Payment Form
    
    private var sendPaymentForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Recipient section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    BodyMBoldText("Recipient")
                        .foregroundColor(.textSecondary)
                    
                    Spacer()
                    
                    Button {
                        showingContactPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle")
                            BodySText("Contacts")
                        }
                        .foregroundColor(.brandAccent)
                    }
                }
                
                HStack {
                    TextField("Recipient Public Key (z-base32)", text: $recipientPubkey)
                        .foregroundColor(.white)
                        .autocapitalization(.none)
                    
                    if !recipientPubkey.isEmpty {
                        Button {
                            recipientPubkey = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
                .padding(12)
                .background(Color.gray6)
                .cornerRadius(8)
                
                // Recipient validation indicator
                if !recipientPubkey.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isValidRecipient(recipientPubkey) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.caption)
                        BodySText(viewModel.isValidRecipient(recipientPubkey) ? "Valid pubkey format" : "Invalid pubkey format")
                    }
                    .foregroundColor(viewModel.isValidRecipient(recipientPubkey) ? .greenAccent : .redAccent)
                }
            }
            
            // Amount section
            VStack(alignment: .leading, spacing: 12) {
                BodyMBoldText("Amount")
                    .foregroundColor(.textSecondary)
                
                HStack {
                    TextField("0", text: Binding(
                        get: { String(amount) },
                        set: { amount = Int64($0) ?? 0 }
                    ))
                    .foregroundColor(.white)
                    .font(.system(size: 32, weight: .bold))
                    .keyboardType(.numberPad)
                    
                    BodyLText("sats")
                        .foregroundColor(.textSecondary)
                }
                .padding(16)
                .background(Color.gray6)
                .cornerRadius(12)
                
                // Quick amounts
                HStack(spacing: 8) {
                    ForEach([1000, 5000, 10000, 50000], id: \.self) { quickAmount in
                        Button {
                            amount = Int64(quickAmount)
                        } label: {
                            BodySText("\(quickAmount)")
                                .foregroundColor(amount == quickAmount ? .white : .textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(amount == quickAmount ? Color.brandAccent : Color.gray5)
                                .cornerRadius(16)
                        }
                    }
                }
            }
            
            // Payment method
            VStack(alignment: .leading, spacing: 12) {
                BodyMBoldText("Payment Method")
                    .foregroundColor(.textSecondary)
                
                Picker("Method", selection: $methodId) {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("Lightning")
                    }.tag("lightning")
                    
                    HStack {
                        Image(systemName: "bitcoinsign.circle.fill")
                        Text("On-Chain")
                    }.tag("onchain")
                }
                .pickerStyle(.segmented)
            }
            
            // Description
            VStack(alignment: .leading, spacing: 12) {
                BodyMBoldText("Note (optional)")
                    .foregroundColor(.textSecondary)
                
                TextField("What's this for?", text: $description)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.gray6)
                    .cornerRadius(8)
            }
            
            // Send button
            Button {
                sendPayment()
            } label: {
                HStack {
                    if viewModel.isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    
                    BodyMBoldText(viewModel.isConnecting ? "Sending..." : "Send Payment")
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(canSend ? Color.brandAccent : Color.gray5)
                .cornerRadius(12)
            }
            .disabled(!canSend)
        }
    }
    
    private var canSend: Bool {
        viewModel.isSessionActive &&
        !recipientPubkey.isEmpty &&
        viewModel.isValidRecipient(recipientPubkey) &&
        amount > 0 &&
        !viewModel.isConnecting
    }
    
    private func sendPayment() {
        guard let payerPubkey = viewModel.currentUserPubkey else {
            app.toast(type: .error, title: "Not connected", description: "Please authenticate with Pubky-ring first")
            return
        }
        
        Task {
            let request = NoisePaymentRequest(
                payerPubkey: payerPubkey,
                payeePubkey: recipientPubkey,
                methodId: methodId,
                amount: "\(amount)",
                currency: "SAT",
                description: description.isEmpty ? nil : description
            )
            
            await viewModel.sendPayment(request)
            
            if let response = viewModel.paymentResponse, response.success {
                app.toast(type: .success, title: "Payment sent!", description: "\(amount) sats to \(truncatePubkey(recipientPubkey))")
                resetForm()
            } else if let error = viewModel.errorMessage {
                app.toast(type: .error, title: "Payment failed", description: error)
            }
        }
    }
    
    private func resetForm() {
        recipientPubkey = ""
        amount = 1000
        description = ""
    }
    
    // MARK: - Receive Payment Section
    
    private var receivePaymentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Your receive info
            if let pubkey = viewModel.currentUserPubkey {
                VStack(alignment: .leading, spacing: 12) {
                    BodyMBoldText("Your Pubkey")
                        .foregroundColor(.textSecondary)
                    
                    HStack {
                        BodyMText(truncatePubkey(pubkey))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        Button {
                            UIPasteboard.general.string = pubkey
                            app.toast(type: .success, title: "Copied to clipboard")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.brandAccent)
                        }
                        
                        Button {
                            // Generate QR code
                        } label: {
                            Image(systemName: "qrcode")
                                .foregroundColor(.brandAccent)
                        }
                    }
                    .padding(12)
                    .background(Color.gray6)
                    .cornerRadius(8)
                }
            }
            
            // Listening status
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(viewModel.isListening ? Color.greenAccent.opacity(0.2) : Color.gray5)
                            .frame(width: 44, height: 44)
                        
                        if viewModel.isListening {
                            Circle()
                                .fill(Color.greenAccent)
                                .frame(width: 12, height: 12)
                                .animation(.easeInOut(duration: 1).repeatForever(), value: viewModel.isListening)
                        }
                        
                        Image(systemName: viewModel.isListening ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(viewModel.isListening ? .greenAccent : .textSecondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        BodyMBoldText(viewModel.isListening ? "Listening for payments..." : "Not listening")
                            .foregroundColor(.white)
                        
                        BodySText(viewModel.isListening ? "Waiting for incoming Noise requests" : "Start listening to receive payments")
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(12)
            
            // Incoming request
            if let request = viewModel.paymentRequest {
                incomingRequestCard(request)
            }
            
            // Start/Stop listening button
            Button {
                Task {
                    if viewModel.isListening {
                        viewModel.stopListening()
                    } else {
                        await viewModel.receivePayment()
                    }
                }
            } label: {
                HStack {
                    Image(systemName: viewModel.isListening ? "stop.fill" : "play.fill")
                    BodyMBoldText(viewModel.isListening ? "Stop Listening" : "Start Listening")
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(viewModel.isSessionActive ? (viewModel.isListening ? Color.orange : Color.brandAccent) : Color.gray5)
                .cornerRadius(12)
            }
            .disabled(!viewModel.isSessionActive)
        }
    }
    
    private func incomingRequestCard(_ request: NoisePaymentRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.2))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.brandAccent)
                        .font(.title2)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    BodyMBoldText("Incoming Payment")
                        .foregroundColor(.white)
                    
                    BodySText("From: \(truncatePubkey(request.payerPubkey))")
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
            }
            
            if let amountStr = request.amount {
                HeadlineLText("\(amountStr) \(request.currency ?? "sats")")
                    .foregroundColor(.white)
            }
            
            if let desc = request.description {
                BodyMText(desc)
                    .foregroundColor(.textSecondary)
            }
            
            HStack(spacing: 12) {
                Button {
                    Task {
                        await viewModel.declineIncomingRequest()
                        app.toast(type: .error, title: "Payment declined")
                    }
                } label: {
                    HStack {
                        Image(systemName: "xmark")
                        BodyMText("Decline")
                    }
                    .foregroundColor(.redAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.redAccent.opacity(0.2))
                    .cornerRadius(8)
                }
                
                Button {
                    Task {
                        await viewModel.acceptIncomingRequest()
                        app.toast(type: .success, title: "Payment accepted!")
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                        BodyMText("Accept")
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.greenAccent)
                    .cornerRadius(8)
                }
            }
        }
        .padding(16)
        .background(Color.gray5)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.brandAccent.opacity(0.5), lineWidth: 1)
        )
    }
    
    private func truncatePubkey(_ pubkey: String) -> String {
        guard pubkey.count > 16 else { return pubkey }
        return "\(pubkey.prefix(8))...\(pubkey.suffix(8))"
    }
}

// MARK: - Contact Picker Sheet

struct ContactPickerSheet: View {
    let onSelect: (PaykitContact) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contactsVM = ContactsViewModel()
    @State private var searchText = ""
    
    var body: some View {
        NavigationView {
            List {
                ForEach(filteredContacts) { contact in
                    Button {
                        onSelect(contact)
                        dismiss()
                    } label: {
                        HStack {
                            ZStack {
                                Circle()
                                    .fill(Color.brandAccent.opacity(0.2))
                                    .frame(width: 40, height: 40)
                                
                                Text(String(contact.name.prefix(1)).uppercased())
                                    .foregroundColor(.brandAccent)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .foregroundColor(.white)
                                Text(contact.pubkey.prefix(16) + "...")
                                    .font(.caption)
                                    .foregroundColor(.textSecondary)
                            }
                            
                            Spacer()
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search contacts")
            .navigationTitle("Select Contact")
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
            contactsVM.loadContacts()
        }
    }
    
    private var filteredContacts: [PaykitContact] {
        if searchText.isEmpty {
            return contactsVM.contacts
        }
        return contactsVM.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.pubkey.localizedCaseInsensitiveContains(searchText)
        }
    }
}

