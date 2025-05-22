import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    
    var body: some View {
        List {
            NavigationLink(destination: DefaultUnitSettingsView()) {
                Text("Default Unit")
            }

            NavigationLink(destination: LocalCurrencySettingsView()) {
                Text("Local Currency")
            }
            
            NavigationLink(destination: TransactionSpeedSettingsView()) {
                Text("Transaction Speed")
            }
        }
        .navigationTitle("General")
    }
}

#Preview {
    NavigationStack {
        GeneralSettingsView()
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
