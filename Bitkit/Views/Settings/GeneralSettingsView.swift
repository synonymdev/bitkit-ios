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

            NavigationLink(destination: WidgetsSettingsView()) {
                Text("Widgets")
            }
        }
        .navigationTitle(localizedString("settings__general_title"))
    }
}

#Preview {
    NavigationStack {
        GeneralSettingsView()
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
