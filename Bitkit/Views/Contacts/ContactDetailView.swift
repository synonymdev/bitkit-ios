import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager

    let publicKey: String

    @State private var profile: PubkyProfile?
    @State private var isLoading = true
    @State private var showAddTagSheet = false
    @State private var hasResolvedContactFromContacts = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__detail_title"))
                .padding(.horizontal, 16)

            if isLoading && profile == nil {
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

    @ViewBuilder
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

    @ViewBuilder
    private var contactActions: some View {
        HStack(spacing: 16) {
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

    @ViewBuilder
    private func linksSection(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(profile.links.enumerated()), id: \.element.id) { index, link in
                ProfileLinkRow(label: link.label, value: link.url, linkIndex: index)
            }
        }
    }

    // MARK: - Tags

    @ViewBuilder
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

    @ViewBuilder
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

    @ViewBuilder
    private var loadingContent: some View {
        VStack {
            Spacer()
            ActivityIndicator(size: 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyContent: some View {
        VStack(spacing: 16) {
            Spacer()
            BodyMText(t("contacts__detail_empty_state"))
            CustomButton(title: t("profile__retry_load"), variant: .secondary) {
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
}

#Preview {
    NavigationStack {
        ContactDetailView(publicKey: "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
