import SwiftUI

struct GeneralSettingsView: View {
    @Environment(UsdtWalletManager.self) private var usdt
    @State private var isUpdatingUsdt = false
    @State private var isCheckingUsdt = false
    @State private var usdtDisableBlocked = false

    @Environment(HwWalletManager.self) private var hwWalletManager

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var tagManager: TagManager
    @StateObject private var languageManager = LanguageManager.shared

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
                .accessibilityIdentifier("LanguageSettings")

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
                .accessibilityIdentifier("TransactionSpeedSettings")

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

                if usdt.isConfigured {
                    SettingsRow(
                        title: t("usdt__settings_title"),
                        iconName: "usdt-settings",
                        rightIcon: nil,
                        toggle: Binding(get: { settings.isUsdtEnabled || usdt.hasFundsOrPendingTransfers },
                                        set: { enabled in Task { await updateUsdt(enabled) } }),
                        disabled: isUpdatingUsdt || isCheckingUsdt || usdt.hasFundsOrPendingTransfers ||
                            (settings.isUsdtEnabled && (usdt.hasProtectedFunds || usdtDisableBlocked)),
                        testIdentifier: "UsdtSettingsToggle"
                    )
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .bottomSafeAreaPadding()
        }
        .task(id: settings.isUsdtEnabled) {
            guard settings.isUsdtEnabled else { usdtDisableBlocked = false; return }
            isCheckingUsdt = true
            defer { isCheckingUsdt = false }
            do {
                try await usdt.checkCanDisable()
                usdtDisableBlocked = false
            } catch UsdtWalletError.cannotDisable {
                usdtDisableBlocked = true
            } catch {}
        }
    }

    private func updateUsdt(_ enabled: Bool) async {
        guard !isUpdatingUsdt else { return }
        isUpdatingUsdt = true
        defer { isUpdatingUsdt = false }
        do {
            if !enabled {
                try await usdt.checkCanDisable()
            }
            settings.usdtPreference = enabled ? .enabled : .disabled
        } catch is CancellationError {
        } catch {
            if case UsdtWalletError.cannotDisable = error {
                usdtDisableBlocked = true
            }
            app.toast(type: .warning, title: t("usdt__settings_title"), description: t("usdt__disable_unavailable"))
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
            .environment(UsdtWalletManager())
    }
    .preferredColorScheme(.dark)
}
