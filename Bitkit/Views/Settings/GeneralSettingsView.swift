import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
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

                NavigationLink(value: app.hasSeenQuickpayIntro ? Route.quickpay : Route.quickpayIntro) {
                    SettingsListLabel(
                        title: localizedString("settings__quickpay__nav_title")
                    )
                }

                NavigationLink(value: app.hasSeenNotificationsIntro ? Route.notifications : Route.notificationsIntro) {
                    SettingsListLabel(
                        title: localizedString("settings__notifications__nav_title")
                    )
                }
            }
            .padding(.horizontal, 16)
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
