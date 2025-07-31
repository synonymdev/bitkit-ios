import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var activityViewModel: ActivityListViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel

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

                if !activityViewModel.recentlyUsedTags.isEmpty {
                    NavigationLink(destination: TagSettingsView()) {
                        SettingsListLabel(
                            title: localizedString("settings__general__tags"),
                            rightText: String(activityViewModel.recentlyUsedTags.count)
                        )
                    }
                }

                NavigationLink(destination: WidgetsSettingsView()) {
                    SettingsListLabel(
                        title: localizedString("settings__widgets__nav_title"),
                        rightText: settings.showWidgets ? "On" : "Off"
                    )
                }

                NavigationLink(value: app.hasSeenQuickpayIntro ? Route.quickpay : Route.quickpayIntro) {
                    SettingsListLabel(
                        title: localizedString("settings__quickpay__nav_title"),
                        rightText: settings.enableQuickpay ? "On" : "Off"
                    )
                }

                NavigationLink(value: app.hasSeenNotificationsIntro ? Route.notifications : Route.notificationsIntro) {
                    SettingsListLabel(
                        title: localizedString("settings__notifications__nav_title"),
                        rightText: settings.notificationServerRegistered ? "On" : "Off"
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
