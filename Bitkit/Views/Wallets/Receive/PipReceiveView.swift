//
//  PipReceiveView.swift
//  Bitkit
//
//  Proof-of-concept PIP receive view for testing PIP SDK integration
//

import SwiftUI
// Note: UniFFI bindings will be imported once library is linked in Xcode project
// For now, using placeholder - actual import will be: import PipUniFFI

struct PipReceiveView: View {
    @State private var amountSats: String = "100000"
    @State private var invoice: String = ""
    @State private var status: String = "Ready"
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var sessionHandle: PipSessionHandle?
    
    // Configuration
    private let receiverUrls = ["http://localhost:8080"] // Mock receiver for testing
    private let esploraUrls = ["http://localhost:3000"] // Mock Esplora for testing
    
    var body: some View {
        VStack(spacing: 20) {
            Text("PIP Receive (Proof of Concept)")
                .font(.title2)
                .bold()
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Amount (sats):")
                    .font(.headline)
                TextField("Enter amount", text: $amountSats)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
            }
            .padding()
            
            Button(action: createQuote) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                } else {
                    Text("Create PIP Quote")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || amountSats.isEmpty)
            
            if let error = errorMessage {
                Text("Error: \(error)")
                    .foregroundColor(.red)
                    .padding()
            }
            
            if !invoice.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Invoice:")
                        .font(.headline)
                    Text(invoice)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    
                    Button("Copy Invoice") {
                        UIPasteboard.general.string = invoice
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Status:")
                    .font(.headline)
                Text(status)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding()
            
            Spacer()
        }
        .padding()
        .navigationTitle("PIP Receive")
    }
    
    private func createQuote() {
        guard let amount = UInt64(amountSats) else {
            errorMessage = "Invalid amount"
            return
        }
        
        isLoading = true
        errorMessage = nil
        status = "Creating quote..."
        
        Task {
            do {
                // TODO: Uncomment once UniFFI library is linked in Xcode project
                /*
                // Build PIP config
                let config = PipConfig(
                    stateDir: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path,
                    esploraUrls: esploraUrls,
                    useTor: false,
                    webhookHmacKey: Data([0x42; 32]), // Mock key for testing
                    tofuMode: "Disabled"
                )
                
                // Build capabilities
                let capabilities = PipCapabilities(
                    parSupported: true,
                    hashlockSupported: true,
                    adaptorSupported: false,
                    reservationSupported: true,
                    packageRelayAssumed: false
                )
                
                // Get a test address (would normally come from wallet)
                let testAddress = "bcrt1qtest1234567890abcdefghijklmnopqrstuvwxyz" // Test address
                
                // Call PIP SDK
                let session = try await pipReceiveLnToOnchain(
                    receiverUrls: receiverUrls,
                    amountSat: amount,
                    merchantAddress: testAddress,
                    capabilities: capabilities,
                    config: config
                )
                */
                
                // Placeholder for proof-of-concept
                await MainActor.run {
                    self.invoice = "lnbc1test... (PIP integration - link library to enable)"
                    self.status = "Proof of concept - library linking required"
                    self.isLoading = false
                }
                return
                
                // TODO: Uncomment once UniFFI library is linked
                /*
                await MainActor.run {
                    self.sessionHandle = session
                    self.invoice = session.invoiceBolt11()
                    self.status = "Quote created: \(session.quoteId())"
                    self.isLoading = false
                }
                
                // Monitor status
                Task {
                    await monitorStatus(session: session)
                }
                */
                
            } catch {
                await MainActor.run {
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    self.status = "Failed"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func monitorStatus(session: PipSessionHandle?) async {
        guard let session = session else { return }
        while true {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                
                // TODO: Uncomment once UniFFI library is linked
                /*
                let currentStatus = session.status()
                await MainActor.run {
                    switch currentStatus {
                    case .quoted:
                        self.status = "Quoted"
                    case .invoicePresented:
                        self.status = "Invoice Presented"
                    case .waitingPreimage:
                        self.status = "Waiting for preimage..."
                    case .preimageReceived(let source):
                        self.status = "Preimage received via \(source)"
                    case .broadcasted(let txid):
                        self.status = "Broadcasted: \(txid)"
                    case .confirmed(let height):
                        self.status = "Confirmed at height \(height)"
                    case .swept(let txid):
                        self.status = "Swept: \(txid)"
                    case .failed(let reason):
                        self.status = "Failed: \(reason)"
                    }
                }
                
                // Stop monitoring if terminal state
                if case .failed = currentStatus {
                    break
                }
                if case .swept = currentStatus {
                    break
                }
                */
                break // Placeholder
                
            } catch {
                break
            }
        }
    }
}

#Preview {
    NavigationStack {
        PipReceiveView()
    }
}

