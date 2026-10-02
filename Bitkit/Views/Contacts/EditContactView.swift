import PhotosUI
import SwiftUI

struct EditContactView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    let publicKey: String

    @State private var form = ContactEditForm()
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    var body: some View {
        ProfileEditFormView(
            navigationTitle: t("contacts__edit_title"),
            name: $form.name,
            bio: $form.bio,
            links: $form.links,
            tags: $form.tags,
            publicKey: publicKey,
            publicKeyLabel: t("profile__create_pubky_label"),
            bioLabel: t("contacts__edit_notes_label"),
            bioPlaceholder: t("contacts__edit_bio_placeholder"),
            isSaving: isSaving,
            footerNote: t("contacts__edit_public_note"),
            deleteLabel: t("contacts__delete_label"),
            deleteActionStyle: .buttonWithIcon,
            onSave: { await saveContact() },
            onCancel: { navigation.navigateBack() },
            onDelete: { showDeleteConfirmation = true }
        ) {
            avatarSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            await loadContactData()
        }
        .alert(t("contacts__delete_title", variables: ["name": form.name]), isPresented: $showDeleteConfirmation) {
            Button(t("contacts__delete_confirm"), role: .destructive) {
                Task { await deleteContact() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("contacts__delete_description", variables: ["name": form.name]))
        }
    }

    // MARK: - Avatar

    private var avatarSection: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Group {
                if let avatarImage {
                    Image(uiImage: avatarImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                } else if let imageUrl = form.imageUrl {
                    PubkyImage(uri: imageUrl, size: 96)
                } else {
                    Circle()
                        .fill(Color.gray5)
                        .frame(width: 96, height: 96)
                        .overlay {
                            Image("user-square")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.white32)
                                .frame(width: 48, height: 48)
                        }
                }
            }
        }
        .accessibilityIdentifier("EditContactAvatar")
        .accessibilityLabel(t("profile__create_avatar_label"))
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await loadSelectedImage(newItem) }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadSelectedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data)
            {
                avatarImage = uiImage
            }
        } catch {
            Logger.error("Failed to load selected image: \(error)", context: "EditContactView")
        }
        selectedPhotoItem = nil
    }

    // MARK: - Data Loading

    /// Fills the form from the contact's row at once, then again once a profile the row was still waiting for arrives.
    private func loadContactData() async {
        fillFormFromContact()
        await contactsManager.resolvePendingContactProfile(publicKey: publicKey)
        fillFormFromContact()
    }

    private func fillFormFromContact() {
        guard let contact = contactsManager.contacts.first(where: { $0.publicKey == publicKey }) else { return }
        form.fill(from: contact.profile)
    }

    // MARK: - Delete

    private func deleteContact() async {
        do {
            try await contactsManager.removeContact(publicKey: publicKey)
            app.toast(
                type: .success,
                title: t("contacts__delete_success"),
                accessibilityIdentifier: "ContactDeletedToast"
            )
            navigation.path = [.contacts]
        } catch let PubkyServiceError.activeSubscription(endsAt) {
            let description = endsAt.map {
                t("subscriptions__expires_date", variables: ["date": $0.formatted(date: .long, time: .omitted)])
            }
            app.toast(type: .error, title: t("contacts__delete_active_subscription"), description: description)
        } catch {
            Logger.error("Failed to delete contact: \(error)", context: "EditContactView")
            app.toast(type: .error, title: t("contacts__delete_error"))
        }
    }

    // MARK: - Save

    /// The save belongs to the Pubky session Save was tapped in. Once that session ends, even while the save still waits
    /// for the contact's profile or uploads the avatar, it stops quietly, with no toast and no navigation. The avatar upload
    /// and the contact save each write nothing once another identity is signed in.
    private func saveContact() async {
        let pubkyProfile = pubkyProfile
        guard !form.trimmedName.isEmpty, let session = pubkyProfile.currentSession else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            let savedProfile = try await contactsManager.saveContactEdit(
                publicKey: publicKey,
                expectedIdentity: session.publicKey,
                isSessionCurrent: { pubkyProfile.currentSession == session }
            ) {
                fillFormFromContact()
                let uploadedImageUrl = if let avatarImage {
                    try await pubkyProfile.uploadAvatar(image: avatarImage, expectedIdentity: session.publicKey)
                } else {
                    form.imageUrl
                }
                return form.edit(imageUrl: uploadedImageUrl)
            }
            guard let savedProfile else { return }
            form.imageUrl = savedProfile.imageUrl
            app.toast(
                type: .success,
                title: t("contacts__edit_saved"),
                accessibilityIdentifier: "ContactUpdatedToast"
            )
            navigation.navigateBack()
        } catch {
            Logger.error("Failed to save contact: \(error)", context: "EditContactView")
            app.toast(type: .error, title: t("contacts__edit_error"))
        }
    }
}

/// The contact edit form's fields. Filling it again, such as when the contact's profile arrives after the form opened,
/// keeps every field the user has changed since the last fill.
struct ContactEditForm {
    var name = ""
    var bio = ""
    var imageUrl: String?
    var links: [ProfileLinkInput] = []
    var tags: [String] = []
    private var filledProfile: PubkyProfile?

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func edit(imageUrl: String?) -> ContactEdit {
        ContactEdit(
            name: trimmedName,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
            imageUrl: imageUrl,
            links: links.map { PubkyProfileLink(label: $0.label, url: $0.url) },
            tags: tags
        )
    }

    mutating func fill(from profile: PubkyProfile) {
        let filled = filledProfile
        if filled.map({ name == $0.name }) ?? true {
            name = profile.name
        }
        if filled.map({ bio == $0.bio }) ?? true {
            bio = profile.bio
        }
        if filled.map({ links.map(\.label) == $0.links.map(\.label) && links.map(\.url) == $0.links.map(\.url) }) ?? true {
            links = profile.links.map { ProfileLinkInput(label: $0.label, url: $0.url) }
        }
        if filled.map({ tags == $0.tags }) ?? true {
            tags = profile.tags
        }
        imageUrl = profile.imageUrl
        filledProfile = profile
    }
}

#Preview {
    NavigationStack {
        EditContactView(publicKey: "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
            .environment(KeyboardManager())
            .environmentObject(PubkyProfileManager())
    }
    .preferredColorScheme(.dark)
}
