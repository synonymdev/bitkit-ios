//
//  NoisePaymentView.swift
//  Bitkit
//
//  Noise payment send/receive view
//

import SwiftUI

struct NoisePaymentView: View {
    @StateObject private var viewModel = NoisePaymentViewModel()
    @EnvironmentObject private var app: AppViewModel
    @State private var mode: PaymentMode = .send
    @State private var recipientPubkey = ""
    @State private var amount: Int64 = 1000
    @State private var methodId = "lightning"
    @State private var description = ""
    
    enum PaymentMode {
        case send
        case receive
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Noise Payment")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
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
            }
        }
        .navigationBarHidden(true)
    }
    
    private var modeSelector: some View {
        Picker("Mode", selection: $mode) {
            Text("Send").tag(PaymentMode.send)
            Text("Receive").tag(PaymentMode.receive)
        }
        .pickerStyle(.segmented)
    }
    
    private var sendPaymentForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                BodyLText("Recipient")
                    .foregroundColor(.textPrimary)
                
                TextField("Recipient Public Key (z-base32)", text: $recipientPubkey)
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
                Task {
                    // TODO: Get current user's pubkey
                    let payerPubkey = "current_user_pubkey"
                    
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
                        app.toast(type: .success, title: "Payment sent successfully")
                    } else if let error = viewModel.errorMessage {
                        app.toast(type: .error, title: "Payment failed", description: error)
                    }
                }
            } label: {
                HStack {
                    if viewModel.isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    
                    BodyMText(viewModel.isConnecting ? "Sending..." : "Send Payment")
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.brandAccent)
                .cornerRadius(8)
            }
            .disabled(recipientPubkey.isEmpty || amount <= 0 || viewModel.isConnecting)
        }
    }
    
    private var receivePaymentSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            BodyLText("Receive Payment")
                .foregroundColor(.textPrimary)
            
            BodyMText("Waiting for incoming Noise payment request...")
                .foregroundColor(.textSecondary)
            
            if viewModel.isConnecting {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
            
            if let request = viewModel.paymentRequest {
                VStack(alignment: .leading, spacing: 16) {
                    BodyMBoldText("Incoming Payment Request")
                        .foregroundColor(.white)
                    
                    BodyMText("From: \(request.payerPubkey.prefix(12))...")
                        .foregroundColor(.textSecondary)
                    
                    if let amount = request.amount {
                        BodyMText("Amount: \(amount) \(request.currency ?? "sats")")
                            .foregroundColor(.textSecondary)
                    }
                    
                    if let desc = request.description {
                        BodyMText("Description: \(desc)")
                            .foregroundColor(.textSecondary)
                    }
                    
                    HStack(spacing: 12) {
                        Button {
                            // Accept payment
                            app.toast(type: .success, title: "Payment accepted")
                        } label: {
                            BodyMText("Accept")
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.greenAccent)
                                .cornerRadius(8)
                        }
                        
                        Button {
                            // Decline payment
                            app.toast(type: .error, title: "Payment declined")
                        } label: {
                            BodyMText("Decline")
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.redAccent)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(16)
                .background(Color.gray900)
                .cornerRadius(8)
            }
            
            Button {
                Task {
                    await viewModel.receivePayment()
                }
            } label: {
                BodyMText("Start Listening")
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.brandAccent)
                    .cornerRadius(8)
            }
            .disabled(viewModel.isConnecting)
        }
    }
}

