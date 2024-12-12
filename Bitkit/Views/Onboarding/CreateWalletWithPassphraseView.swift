import SwiftUI

struct CreateWalletWithPassphraseView: View {
    var body: some View {
        VStack {
            Text("Advanced Setup")
                .font(.largeTitle)
                .padding()
            
            Text("Set up your wallet with a custom passphrase")
                .multilineTextAlignment(.center)
                .padding()
            
            // TODO: Implement advanced setup UI
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        CreateWalletWithPassphraseView()
    }
} 