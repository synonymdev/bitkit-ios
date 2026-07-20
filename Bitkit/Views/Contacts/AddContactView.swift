import SwiftUI

struct AddContactView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let publicKey: String

    @State private var fetchedProfile: PubkyProfile?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var canRetryError = true
    @State private var hasPayableEndpoint = false

    private var truncatedPublicKey: String {
        PubkyPublicKeyFormat.displayTruncated(normalizedPublicKey ?? publicKey)
    }

    private var normalizedPublicKey: String? {
        if case let .valid(normalizedKey) = resolveAddContactValidation(
            input: publicKey,
            ownPublicKey: pubkyProfile.publicKey,
            existingContacts: contactsManager.contacts
        ) {
            return normalizedKey
        }

        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__add_title"))
                .padding(.horizontal, 16)

            if isLoading {
                loadingContent
            } else if let profile = fetchedProfile {
                resultContent(profile)
            } else {
                errorContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            await loadProfile()
        }
    }

    // MARK: - Loading State

    @State private var dashedCircleRotation: Double = 0

    private var loadingContent: some View {
        VStack(spacing: 0) {
            CaptionMText(truncatedPublicKey, textColor: .white64)
                .padding(.top, 24)
                .padding(.bottom, 16)

            ContactAvatarLetter(source: publicKey, size: 96)
                .padding(.bottom, 24)

            DisplayText(t("contacts__add_retrieving"), accentColor: .pubkyGreen)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("AddContactRetrievingTitle")

            Spacer()

            retrievingAnimation

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                dashedCircleRotation = 360
            }
        }
    }

    private var retrievingAnimation: some View {
        ZStack {
            Image("ellipse-outer-green")
                .resizable()
                .scaledToFit()
                .frame(width: 311, height: 311)
                .rotationEffect(.degrees(dashedCircleRotation))

            Image("ellipse-inner-green")
                .resizable()
                .scaledToFit()
                .frame(width: 207, height: 207)
                .rotationEffect(.degrees(-dashedCircleRotation))

            Image("contact-card")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
        }
    }

    // MARK: - Result State

    private func resultContent(_ profile: PubkyProfile) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    CenteredProfileHeader(
                        truncatedKey: profile.truncatedPublicKey,
                        name: profile.name,
                        bio: profile.bio,
                        imageUrl: profile.imageUrl
                    )
                    .padding(.top, 24)
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            BottomActionBar {
                VStack(alignment: .leading, spacing: 16) {
                    BodySText(
                        t("contacts__add_disclaimer", variables: ["name": profile.name]),
                        textColor: .white50
                    )
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 16) {
                        if hasPayableEndpoint {
                            CustomButton(title: t("common__pay"), variant: .secondary) {
                                await payContact()
                            }
                            .accessibilityIdentifier("AddContactPay")
                        }

                        CustomButton(title: t("common__save"), isLoading: isSaving) {
                            await saveContact()
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("AddContactSave")
                    }
                }
            }
        }
    }

    // MARK: - Error State

    private var errorContent: some View {
        VStack(spacing: 16) {
            Spacer()

            BodyMText(errorMessage ?? t("contacts__add_error"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            CustomButton(title: canRetryError ? t("common__retry") : t("common__discard"), variant: .secondary) {
                if canRetryError {
                    await loadProfile()
                } else {
                    navigation.navigateBack()
                }
            }
            .accessibilityIdentifier(canRetryError ? "AddContactRetry" : "AddContactDiscard")

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadProfile() async {
        isLoading = true
        fetchedProfile = nil
        errorMessage = nil
        canRetryError = true
        hasPayableEndpoint = false

        switch resolveAddContactValidation(
            input: publicKey,
            ownPublicKey: pubkyProfile.publicKey,
            existingContacts: contactsManager.contacts
        ) {
        case .empty, .invalidKey:
            errorMessage = t("contacts__add_error_invalid_key")
            canRetryError = false
            isLoading = false
            return
        case .ownKey:
            errorMessage = t("contacts__add_error_self")
            canRetryError = false
            isLoading = false
            return
        case .existingContact:
            errorMessage = t("contacts__add_error_existing")
            canRetryError = false
            isLoading = false
            if let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) {
                await contactsManager.refreshContactReceiverPaths(publicKey: normalizedKey, wallet: wallet)
            }
            return
        case let .valid(normalizedKey):
            if let profile = await contactsManager.fetchContactProfile(publicKey: normalizedKey, includePlaceholder: true) {
                fetchedProfile = profile
                hasPayableEndpoint = await (try? PublicPaykitService.hasPayablePublicEndpoint(publicKey: normalizedKey)) == true
            } else {
                errorMessage = t("contacts__add_error")
            }
        }

        isLoading = false
    }

    // MARK: - Save Contact

    private func saveContact() async {
        isSaving = true
        defer { isSaving = false }

        do {
            guard let normalizedPublicKey else {
                app.toast(type: .error, title: t("contacts__add_error_invalid_key"))
                return
            }

            try await contactsManager.addContact(
                publicKey: normalizedPublicKey,
                existingProfile: fetchedProfile,
                ownPublicKey: pubkyProfile.publicKey
            )
            app.toast(type: .success, title: t("contacts__add_success"), accessibilityIdentifier: "ContactSavedToast")
            navigation.path = [.contacts, .contactSaved(publicKey: normalizedPublicKey)]
        } catch {
            Logger.error("Failed to save contact: \(error)", context: "AddContactView")
            app.toast(type: .error, title: t("contacts__add_error"), description: error.localizedDescription)
        }
    }

    private func payContact() async {
        guard let normalizedPublicKey else {
            app.toast(type: .warning, title: t("slashtags__error_pay_title"), description: t("slashtags__error_pay_empty_msg"))
            return
        }

        do {
            let result = try await PublicPaykitService.beginPayment(to: normalizedPublicKey)

            switch result {
            case let .opened(paymentRequest):
                _ = await openContactPayment(paymentRequest: paymentRequest, publicKey: normalizedPublicKey)
            case .noEndpoint, .notOpened:
                if let messageKey = result.contactPaymentFailureMessageKey {
                    app.toast(
                        type: .warning,
                        title: t("slashtags__error_pay_title"),
                        description: t(messageKey)
                    )
                }
            }
        } catch {
            Logger.error("Failed to pay public pubky \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)", context: "AddContactView")
            app.toast(
                type: .error,
                title: t("slashtags__error_pay_title"),
                description: error.localizedDescription
            )
        }
    }

    @MainActor
    private func openContactPayment(paymentRequest: String, publicKey: String) async -> Bool {
        do {
            try await app.handleScannedData(paymentRequest)
        } catch {
            Logger.warn("Failed to decode contact payment request: \(error)", context: "AddContactView")
            app.toast(
                type: .warning,
                title: t("slashtags__error_pay_title"),
                description: t("slashtags__error_pay_not_opened_msg")
            )
            return false
        }

        guard let route = PaymentNavigationHelper.contactPaymentRoute(app: app, currency: currency, settings: settings) else {
            return false
        }

        navigation.navigateBack()
        app.contactPaymentContext = ContactPaymentContext(publicKey: publicKey)
        sheets.showSheet(.send, data: SendConfig(view: route))
        return true
    }
}

#Preview {
    NavigationStack {
        AddContactView(publicKey: "pubkyz6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(PubkyProfileManager())
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(SheetViewModel())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
