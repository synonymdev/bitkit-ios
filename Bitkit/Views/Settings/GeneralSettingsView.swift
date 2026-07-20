import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = false
    @AppStorage(ContactPaymentsService.confirmedPreferenceKey) private var hasConfirmedContactPaymentsPreference = false
    @AppStorage(PrivatePaykitService.publishingEnabledKey) private var sharesPrivatePaykitEndpoints = false
    @AppStorage(PublicPaykitService.publishingEnabledKey) private var sharesPublicPaykitEndpoints = false

    @Environment(HwWalletManager.self) private var hwWalletManager

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var tagManager: TagManager
    @EnvironmentObject var wallet: WalletViewModel
    @StateObject private var languageManager = LanguageManager.shared
    @State private var isUpdatingContactPayments = false
    @State private var pendingContactPaymentsValue: Bool?

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

    private var contactPaymentsToggle: Binding<Bool> {
        Binding(
            get: {
                pendingContactPaymentsValue ??
                    (hasConfirmedContactPaymentsPreference ? sharesPublicPaykitEndpoints || sharesPrivatePaykitEndpoints : true)
            },
            set: { enabled in
                Task { await updateContactPayments(enabled) }
            }
        )
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
                    SettingsRow(
                        title: t("profile__pay_contacts_toggle"),
                        iconName: "list-dashes",
                        rightIcon: nil,
                        toggle: contactPaymentsToggle,
                        disabled: isUpdatingContactPayments,
                        testIdentifier: "ContactPaymentsToggle"
                    )
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

                NavigationLink(value: Route.hardwareWalletsSettings) {
                    SettingsRow(
                        title: t("settings__hardware_wallets__nav_title"),
                        iconName: "device-mobile-speaker",
                        rightText: hwWalletManager.wallets.isEmpty ? nil : String(hwWalletManager.wallets.count)
                    )
                }
                .accessibilityIdentifier("HardwareWalletsSettings")
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .bottomSafeAreaPadding()
        }
        .task {
            ContactPaymentsService.enableAllPaymentOptions()
        }
    }

    private func updateContactPayments(_ enabled: Bool) async {
        guard !isUpdatingContactPayments else { return }

        isUpdatingContactPayments = true
        pendingContactPaymentsValue = enabled
        defer {
            pendingContactPaymentsValue = nil
            isUpdatingContactPayments = false
        }

        do {
            try await ContactPaymentsService.setEnabled(
                enabled,
                wallet: wallet,
                contactPublicKeys: contactsManager.contacts.map(\.publicKey),
                canUsePrivatePayments: pubkyProfile.hasLocalSecretKeyForCurrentProfile
            )
        } catch {
            Logger.error("Failed to update contact payments: \(error)", context: "GeneralSettingsView")
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        GeneralSettingsView()
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(CurrencyViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(PubkyProfileManager())
            .environmentObject(AppViewModel())
            .environmentObject(WalletViewModel())
            .environment(HwWalletManager())
    }
    .preferredColorScheme(.dark)
}
