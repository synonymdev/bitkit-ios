import SwiftUI

struct PayContactsView: View {
    @AppStorage("hasConfirmedPublicPaykitEndpoints") private var hasConfirmedPublicPaykitEndpoints = false
    @AppStorage(PrivatePaykitService.publishingEnabledKey) private var sharesPrivatePaykitEndpoints = false
    @AppStorage(PublicPaykitService.publishingEnabledKey) private var sharesPublicPaykitEndpoints = false

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var wallet: WalletViewModel

    @State private var enablePayments = true
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("profile__pay_contacts_nav_title"))
                .padding(.horizontal, 16)

            Spacer()

            Image("coin-stack")
                .resizable()
                .scaledToFit()
                .frame(width: 279)
                .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(
                    t("profile__pay_contacts_title"),
                    accentColor: .pubkyGreen
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

                BodyMText(t("profile__pay_contacts_description"), textColor: .white64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            Spacer()

            Toggle(isOn: $enablePayments) {
                BodyMText(t("profile__pay_contacts_toggle"), textColor: .white)
            }
            .tint(.pubkyGreen)
            .disabled(isSaving)
            .accessibilityIdentifier("PayContactsToggle")
            .padding(.horizontal, 32)

            CustomButton(title: t("common__continue"), isLoading: isSaving) {
                await continueFlow()
            }
            .accessibilityIdentifier("PayContactsContinue")
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            enablePayments = hasConfirmedPublicPaykitEndpoints ? (sharesPrivatePaykitEndpoints || sharesPublicPaykitEndpoints) : true
        }
    }

    private func continueFlow() async {
        let publish = enablePayments
        isSaving = true
        defer { isSaving = false }

        do {
            if publish {
                let previousSharesPrivate = sharesPrivatePaykitEndpoints
                let previousSharesPublic = sharesPublicPaykitEndpoints
                let previousConfirmed = hasConfirmedPublicPaykitEndpoints
                do {
                    try await PublicPaykitService.syncPublishedEndpoints(
                        wallet: wallet,
                        publish: true
                    )
                } catch {
                    await rollbackFailedContactPaymentEnable(
                        previousSharesPublic: previousSharesPublic,
                        previousSharesPrivate: previousSharesPrivate,
                        previousConfirmed: previousConfirmed
                    )
                    throw error
                }
                let canUsePrivateContactPayments = pubkyProfile.hasLocalSecretKeyForCurrentProfile
                sharesPrivatePaykitEndpoints = canUsePrivateContactPayments
                sharesPublicPaykitEndpoints = true
                hasConfirmedPublicPaykitEndpoints = true
                if canUsePrivateContactPayments {
                    PrivatePaykitService.setContactSharingCleanupPending(false)
                    await PrivatePaykitService.shared.prepareSavedContacts(
                        contactsManager.contacts.map(\.publicKey),
                        wallet: wallet
                    )
                }
            } else {
                let previousSharesPrivate = sharesPrivatePaykitEndpoints
                let previousSharesPublic = sharesPublicPaykitEndpoints
                var publicCleanupError: Error?
                var privateCleanupError: Error?
                sharesPrivatePaykitEndpoints = false
                sharesPublicPaykitEndpoints = false
                hasConfirmedPublicPaykitEndpoints = true
                do {
                    try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: false)
                    PublicPaykitService.setCleanupPending(false)
                } catch {
                    publicCleanupError = error
                    PublicPaykitService.setCleanupPending(true)
                    Logger.warn("Failed to remove public Paykit endpoints while disabling contact payments: \(error)", context: "PayContactsView")
                }
                do {
                    try await PrivatePaykitService.shared.removePublishedEndpoints()
                } catch {
                    privateCleanupError = error
                    Logger.warn("Failed to remove private Paykit endpoints while disabling contact payments: \(error)", context: "PayContactsView")
                }

                if publicCleanupError != nil {
                    sharesPublicPaykitEndpoints = previousSharesPublic
                    if previousSharesPublic {
                        do {
                            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: true)
                            PublicPaykitService.setCleanupPending(false)
                        } catch {
                            PublicPaykitService.setCleanupPending(true)
                            Logger.warn("Failed to restore public Paykit endpoints after cleanup failure: \(error)", context: "PayContactsView")
                        }
                    }
                }

                if let privateCleanupError {
                    var restoredPrivateSharing = false
                    if previousSharesPrivate {
                        sharesPrivatePaykitEndpoints = true
                        if let restoreError = await PrivatePaykitService.shared.prepareSavedContacts(
                            contactsManager.contacts.map(\.publicKey),
                            wallet: wallet,
                            requireImmediatePublication: true
                        ) {
                            sharesPrivatePaykitEndpoints = false
                            Logger.warn(
                                "Failed to restore private Paykit endpoints after cleanup failure: \(restoreError)",
                                context: "PayContactsView"
                            )
                        } else {
                            restoredPrivateSharing = true
                        }
                    }
                    PrivatePaykitService.setContactSharingCleanupPending(!restoredPrivateSharing)
                }

                if let cleanupError = publicCleanupError ?? privateCleanupError {
                    do {
                        try await PublicPaykitService.syncLocalReceiverMarker(
                            publicSharingEnabled: sharesPublicPaykitEndpoints,
                            privateSharingEnabled: sharesPrivatePaykitEndpoints
                        )
                    } catch {
                        Logger.warn(
                            "Failed to restore Paykit receiver marker after cleanup failure: \(error)",
                            context: "PayContactsView"
                        )
                    }
                    throw cleanupError
                }

                PrivatePaykitService.setContactSharingCleanupPending(false)
            }
            navigation.path = [.profile]
        } catch {
            enablePayments = hasConfirmedPublicPaykitEndpoints ? (sharesPrivatePaykitEndpoints || sharesPublicPaykitEndpoints) : true
            Logger.error("Failed to sync public payment endpoints: \(error)", context: "PayContactsView")
            app.toast(
                type: .error,
                title: t("common__error"),
                description: error.localizedDescription
            )
        }
    }

    private func rollbackFailedContactPaymentEnable(
        previousSharesPublic: Bool,
        previousSharesPrivate: Bool,
        previousConfirmed: Bool
    ) async {
        sharesPublicPaykitEndpoints = previousSharesPublic
        sharesPrivatePaykitEndpoints = previousSharesPrivate
        hasConfirmedPublicPaykitEndpoints = previousConfirmed

        do {
            try await PublicPaykitService.syncPublishedEndpoints(wallet: wallet, publish: previousSharesPublic)
            PublicPaykitService.setCleanupPending(false)
        } catch {
            PublicPaykitService.setCleanupPending(true)
            Logger.warn("Failed to roll back public Paykit endpoints after enabling contact payments failed: \(error)", context: "PayContactsView")
        }
    }
}

#Preview {
    NavigationStack {
        PayContactsView()
            .environmentObject(AppViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
