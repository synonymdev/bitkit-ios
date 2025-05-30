import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        ScrollView {
            NavigationLink(destination: LocalCurrencySettingsView()) {
                SettingsListLabel(
                    title: localizedString("settings__general__currency_local"),
                    rightText: currency.selectedCurrency
                )
            }

            NavigationLink(destination: DefaultUnitSettingsView()) {
                SettingsListLabel(
                    title: localizedString("settings__general__unit"),
                    rightText: currency.primaryDisplay == .bitcoin ? currency.primaryDisplay.rawValue : currency.selectedCurrency
                )
            }

            NavigationLink(destination: TransactionSpeedSettingsView()) {
                SettingsListLabel(
                    title: localizedString("settings__general__speed"),
                    rightText: walletViewModel.defaultTransactionSpeed.displayTitle
                )
            }

            NavigationLink(destination: Text("Coming soon")) {
                SettingsListLabel(
                    title: localizedString("settings__general__app_icon"),
                    rightText: "Orange"
                )
            }

            NavigationLink(destination: TagSettingsView()) {
                SettingsListLabel(
                    title: localizedString("settings__general__tags")
                )
            }

            NavigationLink(destination: WidgetsSettingsView()) {
                SettingsListLabel(
                    title: localizedString("settings__widgets__nav_title")
                )
            }

            NavigationLink(destination: Text("Coming soon")) {
                SettingsListLabel(
                    title: localizedString("settings__quickpay__nav_title")
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
            .environmentObject(CurrencyViewModel())
    }
    .preferredColorScheme(.dark)
}
