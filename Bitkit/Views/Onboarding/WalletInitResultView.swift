import SwiftUI

enum WalletInitResult {
    case created
    case restored
    case failed(Error)
}

struct WalletInitResultView: View {
    @EnvironmentObject var wallet: WalletViewModel
    
    let result: WalletInitResult
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(alignment: .leading, spacing: 0) {
                Text(titleText1)
                    .font(.system(size: 44, weight: .black))
                Text(titleText2)
                    .font(.system(size: 44, weight: .black))
                    .foregroundColor(titleColor)
            
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity, alignment: .center)
            
            Spacer()
            
            Button(action: {
                Haptics.play(.light)
                switch result {
                case .failed:
                    Task {
                        do {
                            wallet.nodeLifecycleState = .initializing
                            try await wallet.start()
                            try wallet.setWalletExistsState()
                        } catch {
                            Logger.error("Failed to start wallet on retry")
                            Haptics.notify(.error)
                        }
                    }
                default:
                    wallet.isRestoringWallet = false
                }
            }) {
                Text(buttonText)
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
    
    private var titleText1: String {
        switch result {
        case .created, .restored:
            return "WALLET"
        case .failed:
            return "WALLET SETUP"
        }
    }
    
    private var titleText2: String {
        switch result {
        case .created:
            return "CREATED"
        case .restored:
            return "RESTORED"
        case .failed:
            return "ERROR"
        }
    }
    
    private var titleColor: Color {
        switch result {
        case .created, .restored:
            return .greenAccent
        case .failed:
            return .redAccent
        }
    }
    
    private var description: String {
        switch result {
        case .created:
            return "Your new wallet is ready to use."
        case .restored:
            return "You have successfully restored your wallet from backup. Enjoy Bitkit!"
        case .failed(let error):
            return "An error occurred: \(error.localizedDescription)"
        }
    }
    
    private var buttonText: String {
        switch result {
        case .created, .restored:
            return "Get Started"
        case .failed:
            return "Try Again"
        }
    }
    
    private var imageName: String {
        switch result {
        case .created, .restored:
            return "check"
        case .failed:
            return "cross"
        }
    }
}

#Preview {
    Group {
        WalletInitResultView(result: .created)
        
        WalletInitResultView(result: .restored)
        
        WalletInitResultView(result: .failed(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])))
    }
    .environmentObject(WalletViewModel())
}
