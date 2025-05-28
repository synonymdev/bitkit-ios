import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel

    var body: some View {
        ScrollView {
            NavigationLink(destination: LocalCurrencySettingsView()) {
                SettingsListLabel(
                    title: "Local Currency"
                )
            }

            NavigationLink(destination: DefaultUnitSettingsView()) {
                SettingsListLabel(
                    title: "Default Unit"
                )
            }

            NavigationLink(destination: TransactionSpeedSettingsView()) {
                SettingsListLabel(
                    title: "Transaction Speed"
                )
            }

            NavigationLink(destination: WidgetsSettingsView()) {
                SettingsListLabel(
                    title: "Widgets"
                )
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
