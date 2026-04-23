import PhotosUI
import SwiftUI

struct EditContactView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    let publicKey: String

    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var imageUrl: String?
    @State private var links: [ProfileLinkInput] = []
    @State private var tags: [String] = []
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__edit_title"))
                .padding(.horizontal, 16)

            ProfileEditFormView(
                name: $name,
                bio: $bio,
                links: $links,
                tags: $tags,
                publicKey: publicKey,
                publicKeyLabel: t("profile__create_pubky_label"),
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            loadContactData()
        }
        .alert(t("contacts__delete_title", variables: ["name": name]), isPresented: $showDeleteConfirmation) {
            Button(t("contacts__delete_confirm"), role: .destructive) {
                Task { await deleteContact() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("contacts__delete_description", variables: ["name": name]))
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarSection: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Group {
                if let avatarImage {
                    Image(uiImage: avatarImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                } else if let imageUrl {
                    PubkyImage(uri: imageUrl, size: 100)
                } else {
                    Circle()
                        .fill(Color.gray5)
                        .frame(width: 100, height: 100)
                        .overlay {
                            Image("user-square")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.white32)
                                .frame(width: 50, height: 50)
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

    private func loadContactData() {
        guard let contact = contactsManager.contacts.first(where: { $0.publicKey == publicKey }) else { return }
        let profile = contact.profile
        name = profile.name
        bio = profile.bio
        imageUrl = profile.imageUrl
        links = profile.links.map { ProfileLinkInput(label: $0.label, url: $0.url) }
        tags = profile.tags
    }

    // MARK: - Delete

    private func deleteContact() async {
        do {
            try await contactsManager.removeContact(publicKey: publicKey)
            app.toast(type: .success, title: t("contacts__delete_success"))
            navigation.path = [.contacts]
        } catch {
            Logger.error("Failed to delete contact: \(error)", context: "EditContactView")
            app.toast(type: .error, title: t("contacts__delete_error"))
        }
    }

    // MARK: - Save

    private func saveContact() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            let uploadedImageUrl = if let avatarImage {
                try await pubkyProfile.uploadAvatar(image: avatarImage)
            } else {
                imageUrl
            }

            try await contactsManager.updateContact(
                publicKey: publicKey,
                name: trimmedName,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                imageUrl: uploadedImageUrl,
                links: links.map { PubkyProfileLink(label: $0.label, url: $0.url) },
                tags: tags
            )
            imageUrl = uploadedImageUrl
            app.toast(type: .success, title: t("contacts__edit_saved"))
            navigation.navigateBack()
        } catch {
            Logger.error("Failed to save contact: \(error)", context: "EditContactView")
            app.toast(type: .error, title: t("contacts__edit_error"))
        }
    }
}

#Preview {
    NavigationStack {
        EditContactView(publicKey: "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(PubkyProfileManager())
    }
    .preferredColorScheme(.dark)
}
