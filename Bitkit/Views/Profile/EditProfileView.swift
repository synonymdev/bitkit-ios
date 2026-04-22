import PhotosUI
import SwiftUI

struct EditProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager

    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var links: [ProfileLinkInput] = []
    @State private var tags: [String] = []
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteFailureOptions = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                NavigationBar(
                    title: t("profile__edit_nav_title")
                )
                .padding(.horizontal, 16)

                ProfileEditFormView(
                    name: $username,
                    bio: $bio,
                    links: $links,
                    tags: $tags,
                    publicKey: pubkyProfile.publicKey ?? "...",
                    publicKeyLabel: t("profile__create_pubky_display_label"),
                    bioPlaceholder: t("profile__create_bio_placeholder"),
                    isSaving: isSaving,
                    footerNote: t("profile__edit_public_note"),
                    deleteLabel: t("profile__delete_label"),
                    deleteActionStyle: .buttonWithIcon,
                    onSave: { await saveProfile() },
                    onCancel: { navigation.navigateBack() },
                    onDelete: { showDeleteConfirmation = true }
                ) {
                    avatarPicker
                }
            }

            if isDeleting {
                Color.customBlack.opacity(0.72)
                    .ignoresSafeArea()

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .disabled(isDeleting)
        .task {
            loadProfileData()
        }
        .alert(t("profile__delete_title"), isPresented: $showDeleteConfirmation) {
            Button(t("profile__delete_confirm"), role: .destructive) {
                Task { await deleteProfile() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("profile__delete_description"))
        }
        .alert(t("profile__delete_error_title"), isPresented: $showDeleteFailureOptions) {
            Button(t("common__retry")) {
                Task { await deleteProfile() }
            }
            Button(t("profile__sign_out"), role: .destructive) {
                Task { await disconnectAfterFailedDelete() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("profile__delete_error_description"))
        }
    }

    // MARK: - Avatar Picker

    @ViewBuilder
    private var avatarPicker: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            avatarContent
        }
        .accessibilityIdentifier("EditProfileAvatar")
        .accessibilityLabel(t("profile__create_avatar_label"))
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await loadSelectedImage(newItem) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let avatarImage {
            Image(uiImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: 100, height: 100)
                .clipShape(Circle())
        } else if let imageUrl = pubkyProfile.profile?.imageUrl {
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

    // MARK: - Image Selection

    private func loadSelectedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data)
            {
                avatarImage = uiImage
            }
        } catch {
            Logger.error("Failed to load selected image: \(error)", context: "EditProfileView")
        }
        selectedPhotoItem = nil
    }

    // MARK: - Data Loading

    private func loadProfileData() {
        guard let profile = pubkyProfile.profile else { return }
        username = profile.name
        bio = profile.bio
        links = profile.links.map { ProfileLinkInput(label: $0.label, url: $0.url) }
        tags = profile.tags
    }

    // MARK: - Delete Profile

    private func deleteProfile() async {
        guard !isDeleting else { return }

        isDeleting = true
        defer { isDeleting = false }

        do {
            try await performDeleteProfile()
        } catch {
            if await pubkyProfile.refreshSessionIfPossible(after: error) {
                do {
                    try await performDeleteProfile()
                    return
                } catch {
                    Logger.error("Failed to delete profile after session refresh: \(error)", context: "EditProfileView")
                }
            } else {
                Logger.error("Failed to delete profile: \(error)", context: "EditProfileView")
            }

            showDeleteFailureOptions = true
        }
    }

    private func performDeleteProfile() async throws {
        try await contactsManager.deleteAllContacts()
        try await pubkyProfile.deleteProfile()
        navigation.path = [app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro]
    }

    private func disconnectAfterFailedDelete() async {
        await pubkyProfile.signOut()
        navigation.path = [app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro]
    }

    // MARK: - Save Profile

    private func saveProfile() async {
        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            var avatarUri: String?
            if let avatarImage {
                avatarUri = try await pubkyProfile.uploadAvatar(image: avatarImage)
            }

            try await pubkyProfile.saveProfile(
                name: trimmedName,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                links: links.map { PubkyProfileLink(label: $0.label, url: $0.url) },
                tags: tags,
                newImageUrl: avatarUri
            )
            app.toast(type: .success, title: t("profile__edit_saved"), accessibilityIdentifier: "ProfileUpdatedToast")
            navigation.navigateBack()
        } catch {
            Logger.error("Failed to save profile: \(error)", context: "EditProfileView")
            app.toast(type: .error, title: t("profile__edit_error_title"), description: error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        EditProfileView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
