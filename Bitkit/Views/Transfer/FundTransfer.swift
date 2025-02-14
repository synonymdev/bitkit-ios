import SwiftUI

struct FundTransfer: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        Text("TODO")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        FundTransfer()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
