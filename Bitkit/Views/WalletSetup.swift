import SwiftUI

struct WalletSetup: View {
    var body: some View {
        VStack {
            Text("Wallet Setup")
                .font(.largeTitle)
                .padding()
            
            Text("Setup your wallet here")
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    WalletSetup()
} 