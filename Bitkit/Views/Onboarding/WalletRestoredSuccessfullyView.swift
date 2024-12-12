import SwiftUI

struct WalletRestoredSuccessfullyView: View {
    @EnvironmentObject var wallet: WalletViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(alignment: .leading, spacing: 0) {
                Text("Wallet")
                    .font(.system(size: 44, weight: .black))
                Text("Restored")
                    .font(.system(size: 44, weight: .black))
                    .foregroundColor(.green)
                
                Text("You have successfully restored your wallet from backup. Enjoy Bitkit!")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image("check")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity, alignment: .center)
            
            Spacer()
            
            Button(action: {
                Haptics.play(.light)
                wallet.isRestoringWallet = false
            }) {
                Text("Get Started")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.gray)
                    .cornerRadius(30)
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .padding(.horizontal)
    }
}

#Preview {
    WalletRestoredSuccessfullyView()
        .environmentObject(WalletViewModel())
} 