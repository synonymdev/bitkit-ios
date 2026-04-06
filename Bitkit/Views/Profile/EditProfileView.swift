import PhotosUI
import SwiftUI

struct EditProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var links: [ProfileLinkInput] = []
    @State private var tags: [String] = []
    @State private var isSaving = false
    @State private var showSignOutConfirmation = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    var body: some View {
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
                isSaving: isSaving,
                deleteLabel: t("profile__sign_out"),
                onSave: { await saveProfile() },
                onCancel: { navigation.navigateBack() },
                onDelete: { showSignOutConfirmation = true }
            ) {
                avatarPicker
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            loadProfileData()
        }
        .alert(t("profile__sign_out_title"), isPresented: $showSignOutConfirmation) {
            Button(t("profile__sign_out"), role: .destructive) {
                Task { await disconnectProfile() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("profile__sign_out_description"))
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

    // MARK: - Disconnect Profile

    private func disconnectProfile() async {
        await pubkyProfile.signOut()
        navigation.reset()
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
            app.toast(type: .success, title: t("profile__edit_saved"))
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
    }
    .preferredColorScheme(.dark)
}
