import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(PaykitFeatureFlags.uiEnabledKey) private var isPaykitUIEnabled = PaykitFeatureFlags.uiEnabledByDefault
    @AppStorage(ContactPaymentsService.confirmedPreferenceKey) private var hasConfirmedContactPaymentsPreference = false
    @AppStorage(PrivatePaykitService.publishingEnabledKey) private var sharesPrivatePaykitEndpoints = false
    @AppStorage(PublicPaykitService.publishingEnabledKey) private var sharesPublicPaykitEndpoints = false
    @AppStorage(PrivatePaykitService.cleanupPendingKey) private var isPrivateSharingCleanupPending = false
    @AppStorage(PublicPaykitService.cleanupPendingKey) private var isPublicSharingCleanupPending = false

    @Environment(UsdtWalletManager.self) private var usdt
    @State private var isUpdatingUsdt = false
    @State private var isCheckingUsdt = false
    @State private var usdtDisableBlocked = false

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
    @State private var isUpdatingPublicPayments = false
    @State private var pendingPublicPaymentsValue: Bool?

    private var isPaykitUIActive: Bool {
        PaykitFeatureFlags.isUIAvailable && isPaykitUIEnabled
    }

    private var contactPaymentsToggle: Binding<Bool> {
        Binding(
            get: {
                pendingContactPaymentsValue ??
                    (hasConfirmedContactPaymentsPreference && sharesPrivatePaykitEndpoints)
            },
            set: { enabled in
                startUpdatingContactPayments(enabled)
            }
        )
    }

    private var publicPaymentsToggle: Binding<Bool> {
        Binding(
            get: { pendingPublicPaymentsValue ?? sharesPublicPaykitEndpoints },
            set: { enabled in startUpdatingPublicPayments(enabled) }
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

                if isPaykitUIActive, pubkyProfile.isAuthenticated {
                    sharingRow(
                        title: t("profile__private_payments_toggle"),
                        toggle: contactPaymentsToggle,
                        isUpdating: isUpdatingContactPayments,
                        isPending: isPrivateSharingCleanupPending,
                        identifier: "PrivateContactPaymentsToggle"
                    )
                    sharingRow(
                        title: t("profile__public_payments_toggle"),
                        toggle: publicPaymentsToggle,
                        isUpdating: isUpdatingPublicPayments,
                        isPending: isPublicSharingCleanupPending,
                        identifier: "PublicPaymentsToggle"
                    )
                }

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
        .task {
            ContactPaymentsService.enableAllPaymentOptions()
            guard isPaykitUIActive,
                  pubkyProfile.isAuthenticated,
                  !hasConfirmedContactPaymentsPreference
            else { return }

            // Leaving the screen cancels `.task`; its own task lets the first contacts load and the enable still finish
            // unless the Pubky session ends or a newer contact payments change starts first.
            startUpdatingContactPayments(true)
        }
    }

    private func sharingRow(title: String, toggle: Binding<Bool>, isUpdating: Bool, isPending: Bool, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView()
                    .opacity(isUpdating ? 1 : 0)
                    .accessibilityHidden(!isUpdating)
                    .frame(width: 20)
                SettingsRow(
                    title: title,
                    rightIcon: nil,
                    toggle: toggle,
                    disabled: isUpdating,
                    testIdentifier: identifier
                )
                .minimumScaleFactor(0.75)
            }
            if isPending, !isUpdating {
                BodySText(t("profile__payments_pending"), textColor: .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        }
    }

    private func startUpdatingPublicPayments(_ enabled: Bool) {
        let admission = ProfileOperationAdmission.shared
        guard !isUpdatingPublicPayments, let scope = try? admission.capture() else { return }
        let owner = pubkyProfile.removalPresentationOwner
        isUpdatingPublicPayments = true
        Task {
            defer { admission.release(scope) }
            await updatePublicPayments(enabled, scope: scope, owner: owner)
        }
    }

    private func updatePublicPayments(_ enabled: Bool, scope: ProfileOperationAdmission.Scope,
                                      owner: PubkyProfileManager.RemovalPresentationOwner) async
    {
        let admission = ProfileOperationAdmission.shared
        pendingPublicPaymentsValue = enabled
        defer {
            pendingPublicPaymentsValue = nil
            isUpdatingPublicPayments = false
        }
        do { try await admission.withScope(scope) {
            guard pubkyProfile.ownsRemovalPresentation(owner) else { throw PubkyServiceError.identityChanged }
            try await ContactPaymentsService.setPublicEnabled(
                enabled, pubkyProfile: pubkyProfile, operations: .live(wallet: wallet)
            )
        } } catch is CancellationError {
            return
        } catch {
            guard (try? admission.validate(scope)) != nil, pubkyProfile.ownsRemovalPresentation(owner) else { return }
            Logger.error("Failed to update public payments: \(error)", context: "GeneralSettingsView")
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
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

    private func startUpdatingContactPayments(_ enabled: Bool) {
        let admission = ProfileOperationAdmission.shared
        guard !isUpdatingContactPayments, let scope = try? admission.capture() else { return }
        let owner = pubkyProfile.removalPresentationOwner
        isUpdatingContactPayments = true
        Task {
            defer { admission.release(scope) }
            await updateContactPayments(enabled, scope: scope, owner: owner)
        }
    }

    private func updateContactPayments(_ enabled: Bool, scope: ProfileOperationAdmission.Scope,
                                       owner: PubkyProfileManager.RemovalPresentationOwner) async
    {
        let admission = ProfileOperationAdmission.shared
        pendingContactPaymentsValue = enabled
        defer {
            pendingContactPaymentsValue = nil
            isUpdatingContactPayments = false
        }

        do { try await admission.withScope(scope) {
            guard pubkyProfile.ownsRemovalPresentation(owner) else { throw PubkyServiceError.identityChanged }
            try await ContactPaymentsService.setEnabled(
                enabled,
                pubkyProfile: pubkyProfile,
                contactsManager: contactsManager,
                operations: .live(wallet: wallet)
            )
        } } catch is CancellationError {
            return
        } catch {
            guard (try? admission.validate(scope)) != nil, pubkyProfile.ownsRemovalPresentation(owner) else { return }
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
            .environment(UsdtWalletManager())
    }
    .preferredColorScheme(.dark)
}
