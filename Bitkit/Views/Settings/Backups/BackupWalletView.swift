import SwiftUI

struct BackupWalletView: View {
    @State private var mnemonic: String = ""
    @State private var showMnemonic: Bool = false
    @State private var copiedToClipboard: Bool = false
    @EnvironmentObject var app: AppViewModel
    
    private var mnemonicWords: [String] {
        mnemonic.split(separator: " ").map(String.init)
    }
    
    private var columnLength: Int {
        let totalWords = mnemonicWords.count
        return totalWords / 2
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if showMnemonic {
                    Text("Write down these \(mnemonicWords.count) words in the right order and store them in a safe place.")
                        .padding()
                        .multilineTextAlignment(.center)
                    
                    VStack(alignment: .leading) {
                        HStack(alignment: .top) {
                            // First column
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(0..<columnLength) { index in
                                    HStack(spacing: 8) {
                                        Text("\(index + 1).")
                                            .foregroundColor(.secondary)
                                        Text(mnemonicWords[index])
                                    }
                                }
                            }
                            .padding()
                            
                            Spacer(minLength: 24)
                            
                            // Second column
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(columnLength..<mnemonicWords.count) { index in
                                    HStack(spacing: 8) {
                                        Text("\(index + 1).")
                                            .foregroundColor(.secondary)
                                        Text(mnemonicWords[index])
                                    }
                                }
                            }
                            .padding()
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            Color(.systemGray6)
                                .opacity(copiedToClipboard ? 0.5 : 1)
                        )
                        .cornerRadius(12)
                        .scaleEffect(copiedToClipboard ? 1.02 : 1)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: copiedToClipboard)
                        .onTapGesture {
                            UIPasteboard.general.string = mnemonic
                            Haptics.play(.copiedToClipboard)
                            
                            withAnimation {
                                copiedToClipboard = true
                            }
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation {
                                    copiedToClipboard = false
                                }
                            }
                        }
                    }
                    .padding()
                } else {
                    Button {
                        Task {
                            do {
                                // Get mnemonic for wallet index 0
                                if let words = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) {
                                    mnemonic = words
                                    showMnemonic = true
                                } else {
                                    app.toast(type: .error, title: "Error", description: "Could not retrieve backup phrase")
                                }
                            } catch {
                                Logger.error("Failed to load mnemonic: \(error)")
                                app.toast(type: .error, title: "Error", description: "Could not retrieve backup phrase")
                            }
                        }
                    } label: {
                        Label("Tap To Reveal", systemImage: "eye")
                            .padding()
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Your Recovery Phrase")
        .navigationBarTitleDisplayMode(.large)
    }
}

#Preview {
    NavigationView {
        BackupWalletView()
            .environmentObject(AppViewModel())
    }
} 