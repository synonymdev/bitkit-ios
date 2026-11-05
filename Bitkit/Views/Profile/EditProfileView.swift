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
        let copy = pubkyProfile.isRingAdoptedIdentity ? RemovalCopy.unlink : RemovalCopy.delete

        ZStack {
            ProfileEditFormView(
                navigationTitle: t("profile__edit_nav_title"),
                name: $username,
                bio: $bio,
                links: $links,
                tags: $tags,
                publicKey: pubkyProfile.publicKey ?? "...",
                publicKeyLabel: t("profile__create_pubky_display_label"),
                bioPlaceholder: t("profile__create_bio_placeholder"),
                isSaving: isSaving,
                footerNote: t("profile__edit_public_note"),
                deleteLabel: copy.label,
                deleteSectionCaption: copy.sectionCaption,
                deleteActionStyle: .buttonWithIcon(icon: copy.icon, isSystemIcon: copy.isSystemIcon),
                onSave: { await saveProfile() },
                onCancel: { navigation.navigateBack() },
                onDelete: { showDeleteConfirmation = true }
            ) {
                avatarPicker
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
        .alert(copy.title, isPresented: $showDeleteConfirmation) {
            Button(copy.confirm, role: .destructive) {
                Task { await deleteProfile() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(copy.description)
        }
        .alert(copy.errorTitle, isPresented: $showDeleteFailureOptions) {
            Button(t("common__retry")) {
                Task { await deleteProfile() }
            }
            Button(t("profile__sign_out"), role: .destructive) {
                Task { await disconnectAfterFailedDelete() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(copy.errorDescription)
        }
    }

    // MARK: - Avatar Picker

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
                .frame(width: 96, height: 96)
                .clipShape(Circle())
        } else if let imageUrl = pubkyProfile.profile?.imageUrl {
            PubkyImage(uri: imageUrl, size: 96)
        } else {
            Circle()
                .fill(Color.gray6)
                .frame(width: 96, height: 96)
                .overlay {
                    Image("picture")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white32)
                        .frame(width: 32, height: 32)
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
        guard let session = pubkyProfile.currentSession else {
            showDeleteFailureOptions = true
            return
        }

        isDeleting = true
        defer { isDeleting = false }
        do {
            try await pubkyProfile.performProfileDeletion {
                do {
                    try await performDeleteProfile(session: session)
                } catch let PubkyServiceError.activeSubscription(endsAt) {
                    guard !Task.isCancelled, pubkyProfile.currentSession == session else { return }
                    let description = endsAt.map {
                        t("subscriptions__expires_date", variables: ["date": $0.formatted(date: .long, time: .omitted)])
                    }
                    app.toast(type: .error, title: t("profile__delete_active_subscription"), description: description)
                } catch {
                    guard !Task.isCancelled, pubkyProfile.publicKey == session.publicKey else { return }
                    Logger.error("Failed to delete profile: \(error)", context: "EditProfileView")
                    showDeleteFailureOptions = true
                }
            }
        } catch {
            guard !Task.isCancelled, pubkyProfile.currentSession == session else { return }
            Logger.error("Failed to delete profile: \(error)", context: "EditProfileView")
            showDeleteFailureOptions = true
        }
    }

    private func performDeleteProfile(session: PubkyProfileManager.SignedInSession) async throws {
        try await Self.performDeleteProfile(session: session, pubkyProfile: pubkyProfile, contactsManager: contactsManager) {
            try await PubkyProfileManager.removePrivatePaykitEndpoints(
                context: "EditProfileView.deleteProfile", deferAppSync: true,
                isSessionCurrent: { pubkyProfile.currentSession == session }
            )
        }
        navigation.path = [app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro]
    }

    static func performDeleteProfile(
        session: PubkyProfileManager.SignedInSession,
        pubkyProfile: PubkyProfileManager,
        contactsManager: ContactsManager,
        removePrivateEndpoints: () async throws -> Void
    ) async throws {
        try await pubkyProfile.validateProfileDeletion(for: session)
        try await removePrivateEndpoints()
        try pubkyProfile.requireCurrentSession(session)
        try await contactsManager.deleteAllContacts()
        try pubkyProfile.requireCurrentSession(session)
        try await pubkyProfile.deleteProfile(cleanPrivatePaykitEndpoints: false, expectedSession: session)
    }

    private func disconnectAfterFailedDelete() async {
        do {
            try await pubkyProfile.signOut()
            navigation.path = [app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro]
        } catch {
            app.toast(type: .error, title: t("profile__sign_out_title"), description: error.localizedDescription)
        }
    }

    // MARK: - Save Profile

    /// The save belongs to the Pubky session Save was tapped in. Once that session ends, even while the avatar still uploads
    /// or the profile publishes, it stops quietly, with no toast and no navigation.
    private func saveProfile() async {
        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            let isSaved = try await pubkyProfile.saveProfile(
                name: trimmedName,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                links: links.map { PubkyProfileLink(label: $0.label, url: $0.url) },
                tags: tags,
                avatarImage: avatarImage
            )
            guard isSaved else { return }
            app.toast(type: .success, title: t("profile__edit_saved"), accessibilityIdentifier: "ProfileUpdatedToast")
            navigation.navigateBack()
        } catch {
            Logger.error("Failed to save profile: \(error)", context: "EditProfileView")
            app.toast(type: .error, title: t("profile__edit_error_title"), description: error.localizedDescription)
        }
    }
}

private struct RemovalCopy {
    let label: String
    let sectionCaption: String
    let icon: String
    let isSystemIcon: Bool
    let title: String
    let confirm: String
    let description: String
    let errorTitle: String
    let errorDescription: String

    static var delete: RemovalCopy {
        RemovalCopy(
            label: t("profile__delete_label"),
            sectionCaption: t("profile__edit_delete_section"),
            icon: "trash",
            isSystemIcon: false,
            title: t("profile__delete_title"),
            confirm: t("profile__delete_confirm"),
            description: t("profile__delete_description"),
            errorTitle: t("profile__delete_error_title"),
            errorDescription: t("profile__delete_error_description")
        )
    }

    static var unlink: RemovalCopy {
        RemovalCopy(
            label: t("profile__unlink_label"),
            sectionCaption: t("profile__edit_unlink_section"),
            icon: "link",
            isSystemIcon: true,
            title: t("profile__unlink_title"),
            confirm: t("profile__unlink_confirm"),
            description: t("profile__unlink_description"),
            errorTitle: t("profile__unlink_error_title"),
            errorDescription: t("profile__unlink_error_description")
        )
    }
}

#Preview {
    NavigationStack {
        EditProfileView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(ContactsManager())
            .environment(KeyboardManager())
    }
    .preferredColorScheme(.dark)
}
