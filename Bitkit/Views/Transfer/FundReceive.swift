import SwiftUI

struct FundReceive: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        Text("FundReceive")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        FundReceive()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
