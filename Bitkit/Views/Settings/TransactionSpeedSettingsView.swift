import SwiftUI

struct TransactionSpeedSettingsView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @State private var showingCustomAlert = false
    @State private var customRate: String = ""
    
    var body: some View {
        List {
            Button(action: {
                wallet.defaultTransactionSpeed = .fast
            }) {
                HStack {
                    Text("Fast")
                    Spacer()
                    if wallet.defaultTransactionSpeed == .fast {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button(action: {
                wallet.defaultTransactionSpeed = .medium
            }) {
                HStack {
                    Text("Medium")
                    Spacer()
                    if wallet.defaultTransactionSpeed == .medium {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button(action: {
                wallet.defaultTransactionSpeed = .slow
            }) {
                HStack {
                    Text("Slow")
                    Spacer()
                    if wallet.defaultTransactionSpeed == .slow {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button(action: {
                // Reset to empty string when opening the alert
                customRate = ""
                showingCustomAlert = true
            }) {
                HStack {
                    Text("Custom")
                    Spacer()
                    if case .custom(let satsPerVByte) = wallet.defaultTransactionSpeed {
                        Text("\(satsPerVByte) sat/vB")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Image(systemName: "checkmark")
                    }
                }
            }
            .alert("Custom Fee Rate", isPresented: $showingCustomAlert) {
                TextField("", text: $customRate)
                    .keyboardType(.numberPad)
                
                Button("OK") {
                    // Only proceed if a value was entered and it's valid
                    if !customRate.isEmpty, let rate = UInt32(customRate), rate > 0 {
                        wallet.defaultTransactionSpeed = .custom(satsPerVByte: rate)
                    }
                }
            } message: {
                Text("Enter the custom fee rate in satoshis per virtual byte")
            }
        }
        .navigationTitle("Transaction Speed")
        .onAppear {
            // Initialize customRate from current setting if it's custom
            if case .custom(let satsPerVByte) = wallet.defaultTransactionSpeed {
                customRate = String(satsPerVByte)
            }
        }
    }
}

#Preview {
    NavigationView {
        TransactionSpeedSettingsView()
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
} 
