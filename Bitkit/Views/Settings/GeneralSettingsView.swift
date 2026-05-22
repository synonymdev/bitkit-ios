import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false
    @AppStorage(PublicPaykitService.lightningPaymentOptionEnabledKey) private var lightningPaymentOptionEnabled = true
    @AppStorage(PublicPaykitService.onchainPaymentOptionEnabledKey) private var onchainPaymentOptionEnabled = true

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var tagManager: TagManager
    @StateObject private var languageManager = LanguageManager.shared

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Interface section
                SettingsSectionHeader(t("settings__general__section_interface"))

                NavigationLink(value: Route.languageSettings) {
                    SettingsRow(
                        title: t("settings__general__language"),
                        iconName: "translate",
                        rightText: languageManager.currentLanguageDisplayName
                    )
                }

                NavigationLink(value: Route.currencySettings) {
                    SettingsRow(
                        title: t("settings__general__currency_local"),
                        iconName: "coins",
                        rightText: "\(currency.selectedCurrency) (\(currency.symbol))"
                    )
                }
                .accessibilityIdentifier("CurrenciesSettings")

                NavigationLink(value: Route.unitSettings) {
                    SettingsRow(
                        title: t("settings__general__unit"),
                        iconName: currency.primaryDisplay == .bitcoin ? "b-unit" : "globe",
                        rightText: currency.primaryDisplay == .bitcoin ? currency.primaryDisplay.rawValue : currency.selectedCurrency
                    )
                }
                .accessibilityIdentifier("UnitSettings")

                NavigationLink(value: Route.widgetsSettings) {
                    SettingsRow(
                        title: t("settings__widgets__nav_title"),
                        iconName: "stack",
                        rightText: settings.showWidgets ? t("common__on") : t("common__off")
                    )
                }
                .accessibilityIdentifier("WidgetsSettings")

                if !tagManager.lastUsedTags.isEmpty {
                    NavigationLink(value: Route.tagSettings) {
                        SettingsRow(
                            title: t("settings__general__tags"),
                            iconName: "tag",
                            rightText: String(tagManager.lastUsedTags.count)
                        )
                    }
                    .accessibilityIdentifier("TagsSettings")
                }

                // Payments section
                SettingsSectionHeader(t("settings__general__section_payments"))
                    .padding(.top, 16)

                NavigationLink(value: Route.transactionSpeedSettings) {
                    SettingsRow(
                        title: t("settings__general__speed"),
                        iconName: settings.defaultTransactionSpeed.iconName,
                        rightText: settings.defaultTransactionSpeed.title
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("TransactionSpeedSettings")

                if isPaykitUIActive, pubkyProfile.isAuthenticated {
                    NavigationLink(value: Route.paymentPreference) {
                        SettingsRow(
                            title: t("settings__adv__payment_preference"),
                            iconName: "list-dashes",
                            rightText: paymentPreferenceSummary
                        )
                    }
                    .accessibilityIdentifier("PaymentPreferenceSettings")
                }

                NavigationLink(value: app.hasSeenQuickpayIntro ? Route.quickpay : Route.quickpayIntro) {
                    SettingsRow(
                        title: t("settings__quickpay__nav_title"),
                        iconName: "caret-double-right",
                        rightText: settings.enableQuickpay ? t("common__on") : t("common__off")
                    )
                }
                .accessibilityIdentifier("QuickpaySettings")

                NavigationLink(value: app.hasSeenNotificationsIntro ? Route.notifications : Route.notificationsIntro) {
                    SettingsRow(
                        title: t("settings__notifications__nav_title"),
                        iconName: "bell",
                        rightText: settings.enableNotifications ? t("common__on") : t("common__off")
                    )
                }
                .accessibilityIdentifier("NotificationsSettings")
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .bottomSafeAreaPadding()
        }
    }

    private var paymentPreferenceSummary: String {
        switch (lightningPaymentOptionEnabled, onchainPaymentOptionEnabled) {
        case (true, true):
            t("settings__adv__pp_both")
        case (true, false):
            t("settings__adv__pp_lightning_short")
        case (false, true):
            t("settings__adv__pp_onchain_short")
        case (false, false):
            t("common__off")
        }
    }
}

#Preview {
    NavigationStack {
        GeneralSettingsView()
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(CurrencyViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
