import SwiftUI

struct RestoreWalletView: View {
    @State private var words: [String] = Array(repeating: "", count: 24)
    @State private var bip39Passphrase: String? = nil
    @State private var showingPassphraseAlert = false
    @State private var tempPassphrase = ""
    @State private var firstFieldText: String = ""
    @State private var is24Words = false
    
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    
    private var wordsPerColumn: Int {
        is24Words ? 12 : 6
    }
    
    private var bip39Mnemonic: String {
        let wordCount = is24Words ? 24 : 12
        return words[..<wordCount]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
    
    var body: some View {
        if #available(iOS 16.0, *) {
            mainBody
                .scrollDismissesKeyboard(.interactively)
        } else {
            mainBody
        }
    }
    
    private var mainBody: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("RESTORE")
                            .font(.largeTitle)
                            .fontWeight(.black)
                            .foregroundColor(.blue)
                        Text("YOUR WALLET")
                            .font(.largeTitle)
                            .fontWeight(.black)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("Please type in your recovery phrase from any (paper) backup.")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    HStack(alignment: .top, spacing: 4) {
                        // First column (1-6 or 1-12)
                        VStack(spacing: 8) {
                            ForEach(0..<wordsPerColumn) { index in
                                HStack(spacing: 4) {
                                    Text("\(index + 1).")
                                        .foregroundColor(.gray)
                                        .padding(.horizontal, 8)
                                    
                                    TextField("", text: index == 0 ? $firstFieldText : $words[index])
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .frame(maxWidth: .infinity)
                                        .onChange(of: firstFieldText) { newValue in
                                            if index == 0 && newValue.contains(" ") {
                                                handlePastedWords(newValue)
                                            } else if index == 0 {
                                                words[index] = newValue
                                            }
                                        }
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(Color(UIColor.systemGray6))
                                .cornerRadius(8)
                            }
                        }
                        
                        // Second column (7-12 or 13-24)
                        VStack(spacing: 8) {
                            ForEach(wordsPerColumn..<(wordsPerColumn * 2)) { index in
                                HStack(spacing: 4) {
                                    Text("\(index + 1).")
                                        .foregroundColor(.gray)
                                        .padding(.horizontal, 8)
                                    
                                    TextField("", text: $words[index])
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(Color(UIColor.systemGray6))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .id(is24Words)
                    .animation(.easeInOut, value: is24Words)
                    .padding(.vertical)
                    
                    // Add some padding at the bottom to ensure content doesn't hide behind buttons
                    Spacer()
                        .frame(height: 100)
                }
                .padding(.horizontal)
            }
            
            // Footer with buttons
            VStack {
                HStack(spacing: 16) {
                    Button(action: { showingPassphraseAlert = true }) {
                        Text("Advanced")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                    }
                    
                    Button(action: restoreWallet) {
                        Text("Restore")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .background(
                    Color(UIColor.systemBackground)
                        .shadow(radius: 8, y: -4)
                )
            }
            .padding(.horizontal)
        }
        
        .navigationBarTitleDisplayMode(.inline)
        .alert("BIP39 Passphrase", isPresented: $showingPassphraseAlert) {
            TextField("Enter passphrase", text: $tempPassphrase)
                .autocapitalization(.none)
                .autocorrectionDisabled()
            Button("OK") {
                bip39Passphrase = tempPassphrase.isEmpty ? nil : tempPassphrase
                tempPassphrase = ""
            }
            Button("Cancel", role: .cancel) {
                tempPassphrase = ""
            }
        } message: {
            Text("Enter an optional passphrase for additional security.")
        }
    }
    
    private func restoreWallet() {
        // TODO: validate mnemonic

        do {
            wallet.nodeLifecycleState = .initializing
            _ = try StartupHandler.restoreWallet(mnemonic: bip39Mnemonic, bip39Passphrase: bip39Passphrase)
            try wallet.setWalletExistsState()
        } catch {
            app.toast(error)
        }
    }
    
    private func handlePastedWords(_ pastedText: String) {
        let pastedWords = pastedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        
        // Check if it's a valid 12 or 24 word phrase
        guard pastedWords.count == 12 || pastedWords.count == 24 else { return }
        
        // Update state first
        withAnimation {
            is24Words = pastedWords.count == 24
        }
        
        // Update all fields
        for (index, word) in pastedWords.enumerated() {
            words[index] = word.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Clear unused fields if switching from 24 to 12 words
        if !is24Words {
            for index in 12..<24 {
                words[index] = ""
            }
        }
        
        // Clear the first field's temporary text
        firstFieldText = words[0]
    }
}

#Preview {
    NavigationView {
        RestoreWalletView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
    }
}
