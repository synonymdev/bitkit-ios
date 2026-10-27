import PhotosUI
import SwiftUI

struct EditProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager

    @State private var screenOwner: PubkyProfileManager.RemovalPresentationOwner?
    @State private var username: String = ""
    @State private var bio: String = ""
    @State private var links: [ProfileLinkInput] = []
    @State private var tags: [String] = []
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var removalConfirmation: PubkyProfileManager.RemovalConfirmation?
    @State private var confirmationOwner: PubkyProfileManager.RemovalPresentationOwner?
    @State private var preparationTask: Task<Void, Never>?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    var body: some View {
        let copy = (removalConfirmation?.action == .unlink || (removalConfirmation == nil && pubkyProfile.isRingAdoptedIdentity)) ? RemovalCopy
            .unlink : RemovalCopy.delete

        Group {
            if pubkyProfile.removalRecovery != .ready, !isDeleting {
                ProfileRemovalRecoveryView()
            } else {
                editContent(copy: copy)
            }
        }
    }

    private func editContent(copy: RemovalCopy) -> some View {
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
                onDelete: {
                    guard let owner = screenOwner, pubkyProfile.ownsRemovalPresentation(owner) else { return }
                    preparationTask = Task { await prepareDelete(owner: owner) }
                }
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
            if screenOwner == nil {
                screenOwner = pubkyProfile.removalPresentationOwner
            }
            loadProfileData()
        }
        .onDisappear {
            preparationTask?.cancel()
            pubkyProfile.cancelRemovalConfirmation(removalConfirmation)
        }
        .alert(copy.title, isPresented: $showDeleteConfirmation) {
            Button(copy.confirm, role: .destructive) {
                Task { await deleteProfile() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) { pubkyProfile.cancelRemovalConfirmation(removalConfirmation) }
        } message: {
            Text(copy.description)
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

    private func prepareDelete(owner presentationOwner: PubkyProfileManager.RemovalPresentationOwner) async {
        guard !isDeleting, pubkyProfile.ownsRemovalPresentation(presentationOwner) else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            removalConfirmation = try await pubkyProfile.prepareRemoval(
                action: pubkyProfile.isRingAdoptedIdentity ? .unlink : .deleteProfile, contacts: contactsManager, expectedOwner: presentationOwner
            )
            confirmationOwner = presentationOwner
            showDeleteConfirmation = true
        } catch {
            guard !Task.isCancelled, pubkyProfile.ownsRemovalPresentation(presentationOwner) else { return }
            app.toast(type: .error, title: t("profile__sign_out_title"), description: error.localizedDescription)
        }
    }

    private func deleteProfile() async {
        guard !isDeleting, let confirmation = removalConfirmation, let presentationOwner = confirmationOwner else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            let result = try await pubkyProfile.confirmRemoval(confirmation)
            if pubkyProfile.ownsRemovalCompletion(result) {
                navigation.path = [app.hasSeenProfileIntro ? .pubkyChoice : .profileIntro]
            }
        } catch {
            pubkyProfile.refreshRemovalRecovery()
            guard !Task.isCancelled, pubkyProfile.ownsRemovalFailure(confirmation, owner: presentationOwner) else { return }
            if pubkyProfile.pendingProfileRemovalID != confirmation.id {
                app.toast(type: .error, title: t("profile__sign_out_title"), description: error.localizedDescription)
            }
        }
    }

    // MARK: - Save Profile

    /// The save belongs to the Pubky session Save was tapped in. Once that session ends, even while the avatar still uploads
    /// or the profile publishes, it stops quietly, with no toast and no navigation.
    private func saveProfile() async {
        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let screenOwner, pubkyProfile.ownsRemovalPresentation(screenOwner) else { return }

        let admission = ProfileOperationAdmission.shared
        guard let scope = try? admission.capture() else { return }
        defer { admission.release(scope) }
        isSaving = true
        defer { isSaving = false }

        do {
            try await admission.withScope(scope) {
                let isSaved = try await pubkyProfile.saveProfile(
                    name: trimmedName,
                    bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                    links: links.map { PubkyProfileLink(label: $0.label, url: $0.url) },
                    tags: tags,
                    avatarImage: avatarImage
                )
                try admission.checkCurrent()
                guard isSaved, pubkyProfile.ownsRemovalPresentation(screenOwner) else { return }
                app.toast(type: .success, title: t("profile__edit_saved"), accessibilityIdentifier: "ProfileUpdatedToast")
                navigation.navigateBack()
            }
        } catch {
            guard !Task.isCancelled, (try? admission.validate(scope)) != nil,
                  pubkyProfile.ownsRemovalPresentation(screenOwner) else { return }
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

    static var delete: RemovalCopy {
        RemovalCopy(
            label: t("profile__delete_label"),
            sectionCaption: t("profile__edit_delete_section"),
            icon: "trash",
            isSystemIcon: false,
            title: t("profile__delete_title"),
            confirm: t("profile__delete_confirm"),
            description: t("profile__delete_description")
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
            description: t("profile__unlink_description")
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
