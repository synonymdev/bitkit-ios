import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    let publicKey: String

    @State private var profile: PubkyProfile?
    @State private var isLoading = true
    @State private var showAddTagSheet = false
    @State private var hasResolvedContactFromContacts = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__detail_title"))
                .padding(.horizontal, 16)

            if isLoading {
                loadingContent
            } else if let profile {
                contactBody(profile)
            } else {
                emptyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            if let cached = contactsManager.contacts.first(where: { $0.publicKey == publicKey }) {
                profile = cached.profile
                hasResolvedContactFromContacts = true
                isLoading = false
            }
            isLoading = false
        }
        .onReceive(contactsManager.$contacts) { updatedContacts in
            if let cached = updatedContacts.first(where: { $0.publicKey == publicKey }) {
                profile = cached.profile
                hasResolvedContactFromContacts = true
            } else if hasResolvedContactFromContacts {
                hasResolvedContactFromContacts = false
                profile = nil
                navigation.path = [.contacts]
            }
        }
    }

    // MARK: - Contact Body

    private func contactBody(_ profile: PubkyProfile) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                CenteredProfileHeader(
                    truncatedKey: profile.truncatedPublicKey,
                    name: profile.name,
                    bio: profile.bio,
                    imageUrl: profile.imageUrl,
                    nameAccessibilityIdentifier: "ContactViewName",
                    notesAccessibilityIdentifier: "ContactViewNotes"
                )
                .padding(.top, 24)
                .padding(.bottom, 24)

                contactActions
                    .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 0) {
                    if !profile.links.isEmpty {
                        linksSection(profile)
                    }

                    tagsSection(profile)
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showAddTagSheet) {
            AddProfileTagSheet { newTag in
                addTag(newTag)
            }
        }
    }

    // MARK: - Action Buttons

    private var contactActions: some View {
        HStack(spacing: 16) {
            GradientCircleButton(icon: "coins", accessibilityLabel: t("wallet__send")) {
                Task {
                    await payContact()
                }
            }
            .accessibilityIdentifier("ContactPay")

            GradientCircleButton(icon: "activity", accessibilityLabel: t("wallet__activity")) {
                navigation.navigate(.contactActivity(publicKey: publicKey))
            }
            .accessibilityIdentifier("ContactActivity")

            GradientCircleButton(icon: "copy", accessibilityLabel: t("common__copy")) {
                UIPasteboard.general.string = publicKey
                app.toast(type: .success, title: t("common__copied"))
            }
            .accessibilityIdentifier("ContactCopy")

            GradientCircleButton(icon: "share", accessibilityLabel: t("common__share")) {
                shareContact()
            }
            .accessibilityIdentifier("ContactShare")

            GradientCircleButton(icon: "pencil", accessibilityLabel: t("common__edit")) {
                navigation.navigate(.editContact(publicKey: publicKey))
            }
            .accessibilityIdentifier("ContactEdit")
        }
    }

    // MARK: - Links / Metadata

    private func linksSection(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(profile.links.enumerated()), id: \.element.id) { index, link in
                ProfileLinkRow(label: link.label, value: link.url, linkIndex: index)
            }
        }
    }

    // MARK: - Tags

    private func tagsSection(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("profile__create_tags_label"), textColor: .white64)
                .accessibilityIdentifier("ContactViewTagsHeader")

            WrappingHStack(spacing: 8) {
                ForEach(profile.tags, id: \.self) { tag in
                    Tag(tag, icon: .close, onDelete: {
                        removeTag(tag)
                    })
                }

                addTagButton
            }
        }
    }

    private var addTagButton: some View {
        IconActionButton(
            icon: "tag",
            title: t("profile__create_add_tag"),
            accessibilityId: "ContactAddTag"
        ) {
            showAddTagSheet = true
        }
    }

    // MARK: - Tag Persistence

    private func addTag(_ newTag: String) {
        guard var current = profile else { return }
        current = PubkyProfile(
            publicKey: current.publicKey,
            name: current.name,
            bio: current.bio,
            imageUrl: current.imageUrl,
            links: current.links,
            tags: current.tags + [newTag],
            status: current.status
        )
        profile = current
        persistContact(current)
    }

    private func removeTag(_ tag: String) {
        guard var current = profile else { return }
        current = PubkyProfile(
            publicKey: current.publicKey,
            name: current.name,
            bio: current.bio,
            imageUrl: current.imageUrl,
            links: current.links,
            tags: current.tags.filter { $0 != tag },
            status: current.status
        )
        profile = current
        persistContact(current)
    }

    private func persistContact(_ profile: PubkyProfile) {
        Task {
            do {
                try await contactsManager.updateContact(
                    publicKey: publicKey,
                    name: profile.name,
                    bio: profile.bio,
                    imageUrl: profile.imageUrl,
                    links: profile.links,
                    tags: profile.tags
                )
            } catch {
                Logger.error("Failed to persist contact tags: \(error)", context: "ContactDetailView")
                app.toast(type: .error, title: t("contacts__error_saving"))
            }
        }
    }

    // MARK: - Loading & Empty States

    private var loadingContent: some View {
        VStack {
            Spacer()
            ActivityIndicator(size: 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyContent: some View {
        VStack(spacing: 16) {
            Spacer()
            BodyMText(t("contacts__detail_empty_state"))
            CustomButton(title: t("profile__retry_load"), variant: .secondary) {
                isLoading = true
                defer { isLoading = false }

                if let contact = contactsManager.contacts.first(where: { $0.publicKey == publicKey }) {
                    profile = contact.profile
                } else if let fetched = await contactsManager.fetchContactProfile(publicKey: publicKey) {
                    profile = fetched
                }
            }
            .accessibilityIdentifier("ContactRetry")
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Share

    private func shareContact() {
        let activityVC = UIActivityViewController(
            activityItems: [publicKey],
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController
        {
            var presentingVC = rootViewController
            while let presented = presentingVC.presentedViewController {
                presentingVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = presentingVC.view
            presentingVC.present(activityVC, animated: true)
        }
    }

    private func payContact() async {
        do {
            let result = try await PrivatePaykitService.shared.beginSavedContactPayment(to: publicKey, wallet: wallet)

            switch result {
            case let .opened(paymentRequest, privatePaymentContext):
                _ = await openContactPayment(paymentRequest: paymentRequest, privatePaymentContext: privatePaymentContext)
            case .noEndpoint, .notOpened, .waitingForUpdatedPaymentList:
                if let messageKey = result.contactPaymentFailureMessageKey {
                    app.toast(
                        type: .warning,
                        title: t("slashtags__error_pay_title"),
                        description: t(messageKey)
                    )
                }
            }
        } catch {
            Logger.error("Failed to pay contact \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)", context: "ContactDetailView")
            app.toast(
                type: .error,
                title: t("slashtags__error_pay_title"),
                description: error.localizedDescription
            )
        }
    }

    @MainActor
    private func openContactPayment(paymentRequest: String, privatePaymentContext: PrivatePaykitPaymentContext?) async -> Bool {
        do {
            try await app.handleScannedData(paymentRequest)
        } catch {
            Logger.warn("Failed to decode contact payment request: \(error)", context: "ContactDetailView")
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

        app.contactPaymentContext = ContactPaymentContext(publicKey: publicKey, privatePaymentContext: privatePaymentContext)
        sheets.showSheet(.send, data: SendConfig(view: route))
        return true
    }
}

#Preview {
    NavigationStack {
        ContactDetailView(publicKey: "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(SettingsViewModel.shared)
            .environmentObject(SheetViewModel())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}
