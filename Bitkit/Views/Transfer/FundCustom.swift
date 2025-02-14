import SwiftUI

struct FundCustom: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        Text("TODO")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        FundCustom()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
