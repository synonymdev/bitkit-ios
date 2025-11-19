import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var tagManager: TagManager
    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general_title"))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink(value: Route.languageSettings) {
                        SettingsListLabel(
                            title: t("settings__general__language"),
                            rightText: languageManager.currentLanguageDisplayName
                        )
                    }

                    NavigationLink(value: Route.currencySettings) {
                        SettingsListLabel(
                            title: t("settings__general__currency_local"),
                            rightText: currency.selectedCurrency
                        )
                    }
                    .accessibilityIdentifier("CurrenciesSettings")

                    NavigationLink(value: Route.unitSettings) {
                        SettingsListLabel(
                            title: t("settings__general__unit"),
                            rightText: currency.primaryDisplay == .bitcoin ? currency.primaryDisplay.rawValue : currency.selectedCurrency
                        )
                    }
                    .accessibilityIdentifier("UnitSettings")

                    NavigationLink(value: Route.transactionSpeedSettings) {
                        SettingsListLabel(
                            title: t("settings__general__speed"),
                            rightText: settings.defaultTransactionSpeed.displayTitle
                        )
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("TransactionSpeedSettings")

                    if !tagManager.lastUsedTags.isEmpty {
                        NavigationLink(value: Route.tagSettings) {
                            SettingsListLabel(
                                title: t("settings__general__tags"),
                                rightText: String(tagManager.lastUsedTags.count)
                            )
                        }
                        .accessibilityIdentifier("TagsSettings")
                    }

                    NavigationLink(value: Route.widgetsSettings) {
                        SettingsListLabel(
                            title: t("settings__widgets__nav_title"),
                            rightText: settings.showWidgets ? tTodo("On") : tTodo("Off")
                        )
                    }
                    .accessibilityIdentifier("WidgetsSettings")

                    NavigationLink(value: app.hasSeenQuickpayIntro ? Route.quickpay : Route.quickpayIntro) {
                        SettingsListLabel(
                            title: t("settings__quickpay__nav_title"),
                            rightText: settings.enableQuickpay ? tTodo("On") : tTodo("Off")
                        )
                    }
                    .accessibilityIdentifier("QuickpaySettings")

                    NavigationLink(value: app.hasSeenNotificationsIntro ? Route.notifications : Route.notificationsIntro) {
                        SettingsListLabel(
                            title: t("settings__notifications__nav_title"),
                            rightText: settings.enableNotifications ? tTodo("On") : tTodo("Off")
                        )
                    }
                    .accessibilityIdentifier("NotificationsSettings")
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        GeneralSettingsView()
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(CurrencyViewModel())
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
