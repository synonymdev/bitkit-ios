import SwiftUI

struct FundCustomView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        Text("FundCustomView")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        FundCustomView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
