import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var app: AppViewModel

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
                    rightText: settings.defaultTransactionSpeed.displayTitle
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

            NavigationLink(value: app.hasSeenWidgetsIntro ? Route.widgetsList : Route.widgetsIntro) {
                SettingsListLabel(
                    title: localizedString("settings__widgets__nav_title")
                )
            }

            NavigationLink(value: app.hasSeenQuickpayIntro ? Route.quickpay : Route.quickpayIntro) {
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
            .environmentObject(SettingsViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
