import SwiftUI

struct FundReceiveView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        Text("FundReceiveView")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        FundReceiveView()
            .environmentObject(WalletViewModel())
            .environmentObject(AppViewModel())
            .preferredColorScheme(.dark)
    }
}
