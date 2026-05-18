import SwiftUI

struct PaymentPreferenceView: View {
    @AppStorage("hasConfirmedPublicPaykitEndpoints") private var hasConfirmedPublicPaykitEndpoints = false
    @AppStorage(PublicPaykitService.lightningPaymentOptionEnabledKey) private var lightningPaymentOptionEnabled = true
    @AppStorage(PublicPaykitService.onchainPaymentOptionEnabledKey) private var onchainPaymentOptionEnabled = true
    @AppStorage(PrivatePaykitService.publishingEnabledKey) private var sharesPrivatePaykitEndpoints = false
    @AppStorage(PublicPaykitService.publishingEnabledKey) private var sharesPublicPaykitEndpoints = false

    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var wallet: WalletViewModel

    @State private var isUpdatingPaymentOptions = false
    @State private var isUpdatingPrivate = false
    @State private var isUpdatingPublic = false

    private var lightningOptionToggle: Binding<Bool> {
        Binding(
            get: { lightningPaymentOptionEnabled },
            set: { value in
                Task { await updatePaymentOption(.lightning, enabled: value) }
            }
        )
    }

    private var onchainOptionToggle: Binding<Bool> {
        Binding(
            get: { onchainPaymentOptionEnabled },
            set: { value in
                Task { await updatePaymentOption(.onchain, enabled: value) }
            }
        )
    }

    private var privateToggle: Binding<Bool> {
        Binding(
            get: { sharesPrivatePaykitEndpoints },
            set: { value in
                Task { await updatePrivateSharing(value) }
            }
        )
    }

    private var publicToggle: Binding<Bool> {
        Binding(
            get: { sharesPublicPaykitEndpoints },
            set: { value in
                Task { await updatePublicSharing(value) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("settings__adv__payment_preference"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    BodyMText(t("settings__adv__pp_header"), textColor: .white64)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 32)
                        .padding(.bottom, 16)

                    SettingsSectionHeader(t("settings__adv__pp_options").localizedUppercase)

                    SettingsRow(
                        title: t("settings__adv__pp_lightning"),
                        rightIcon: nil,
                        toggle: lightningOptionToggle,
                        disabled: isUpdatingPaymentOptions || (lightningPaymentOptionEnabled && !onchainPaymentOptionEnabled),
                        testIdentifier: "LightningPaymentOptionToggle"
                    )

                    SettingsRow(
                        title: t("settings__adv__pp_onchain"),
                        rightIcon: nil,
                        toggle: onchainOptionToggle,
                        disabled: isUpdatingPaymentOptions || (onchainPaymentOptionEnabled && !lightningPaymentOptionEnabled),
                        testIdentifier: "OnchainPaymentOptionToggle"
                    )

                    if pubkyProfile.isAuthenticated {
                        SettingsSectionHeader(t("settings__adv__pp_contacts").localizedUppercase)
                            .padding(.top, 16)

                        SettingsRow(
                            title: t("settings__adv__pp_private_contacts"),
                            rightIcon: nil,
                            toggle: privateToggle,
                            disabled: isUpdatingPrivate,
                            testIdentifier: "PrivateContactPaymentsToggle"
                        )

                        SettingsRow(
                            title: t("settings__adv__pp_public_contacts"),
                            rightIcon: nil,
                            toggle: publicToggle,
                            disabled: isUpdatingPublic,
                            testIdentifier: "PublicContactPaymentsToggle"
                        )
                    }

                    Spacer(minLength: 220)

                    if pubkyProfile.isAuthenticated {
                        BodySText(t("settings__adv__pp_public_footer"), textColor: .white64)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .background(Color.customBlack)
        .navigationBarHidden(true)
    }

    private func updatePrivateSharing(_ enabled: Bool) async {
        guard !isUpdatingPrivate else { return }
        guard !enabled || pubkyProfile.isAuthenticated else {
            showProfileRequiredError()
            return
        }
        isUpdatingPrivate = true
        sharesPrivatePaykitEndpoints = enabled
        hasConfirmedPublicPaykitEndpoints = true
        defer { isUpdatingPrivate = false }

        if enabled {
            PrivatePaykitService.setContactSharingCleanupPending(false)
            await PrivatePaykitService.shared.prepareSavedContacts(
                contactsManager.contacts.map(\.publicKey),
                wallet: wallet
            )
        } else {
            do {
                try await PrivatePaykitService.shared.removePublishedEndpoints()
                PrivatePaykitService.setContactSharingCleanupPending(false)
            } catch {
                PrivatePaykitService.setContactSharingCleanupPending(true)
                Logger.warn("Deferred private contact payment cleanup after disable failed: \(error)", context: "PaymentPreferenceView")
            }
        }
    }

    private func updatePublicSharing(_ enabled: Bool) async {
        guard !isUpdatingPublic else { return }
        guard !enabled || pubkyProfile.isAuthenticated else {
            showProfileRequiredError()
            return
        }
        isUpdatingPublic = true
        let previousValue = sharesPublicPaykitEndpoints
        sharesPublicPaykitEndpoints = enabled
        hasConfirmedPublicPaykitEndpoints = true
        defer { isUpdatingPublic = false }

        do {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: enabled)
        } catch {
            sharesPublicPaykitEndpoints = previousValue
            Logger.error("Failed to update public contact payments: \(error)", context: "PaymentPreferenceView")
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        }
    }

    private enum PaymentOption {
        case lightning
        case onchain
    }

    private func updatePaymentOption(_ option: PaymentOption, enabled: Bool) async {
        guard !isUpdatingPaymentOptions else { return }
        guard enabled || canDisablePaymentOption(option) else { return }

        isUpdatingPaymentOptions = true
        let previousLightning = lightningPaymentOptionEnabled
        let previousOnchain = onchainPaymentOptionEnabled

        switch option {
        case .lightning:
            lightningPaymentOptionEnabled = enabled
        case .onchain:
            onchainPaymentOptionEnabled = enabled
        }

        defer { isUpdatingPaymentOptions = false }

        do {
            try await refreshPublishedPaymentOptions()
        } catch {
            lightningPaymentOptionEnabled = previousLightning
            onchainPaymentOptionEnabled = previousOnchain
            await refreshPublishedPaymentOptionsBestEffort()
            Logger.error("Failed to update payment options: \(error)", context: "PaymentPreferenceView")
            app.toast(type: .error, title: t("common__error"), description: error.localizedDescription)
        }
    }

    private func canDisablePaymentOption(_ option: PaymentOption) -> Bool {
        switch option {
        case .lightning:
            return onchainPaymentOptionEnabled
        case .onchain:
            return lightningPaymentOptionEnabled
        }
    }

    private func showProfileRequiredError() {
        app.toast(type: .error, title: t("common__error"), description: t("profile__session_expired_description"))
    }

    private func refreshPublishedPaymentOptions() async throws {
        if sharesPublicPaykitEndpoints {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: true)
        }

        if sharesPrivatePaykitEndpoints {
            if let privatePublishError = await PrivatePaykitService.shared.prepareSavedContacts(
                contactsManager.contacts.map(\.publicKey),
                wallet: wallet,
                requireImmediatePublication: true
            ) {
                throw privatePublishError
            }
        }
    }

    private func refreshPublishedPaymentOptionsBestEffort() async {
        if sharesPublicPaykitEndpoints {
            do {
                try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: true)
            } catch {
                Logger.warn("Failed to restore public payment options after preference rollback: \(error)", context: "PaymentPreferenceView")
            }
        }

        if sharesPrivatePaykitEndpoints {
            await PrivatePaykitService.shared.prepareSavedContacts(
                contactsManager.contacts.map(\.publicKey),
                wallet: wallet
            )
        }
    }
}
