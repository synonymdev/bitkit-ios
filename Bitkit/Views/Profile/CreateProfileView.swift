import PhotosUI
import SwiftUI

struct CreateProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var screenOwner: PubkyProfileManager.RemovalPresentationOwner?
    @State private var screenGeneration: ProfileOperationAdmission.Generation?
    @State private var loadGeneration = 0
    @State private var derivedPublicKey: String = ""
    @State private var username: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isRestoring = false
    @State private var remoteLookupFailed = false
    @State private var existingProfile: PubkyProfile?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarImage: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(
                title: t(isRestoring ? "profile__restore_nav_title" : "profile__create_nav_title")
            )
            .padding(.horizontal, 16)

            if isLoading {
                loadingView
            } else {
                formContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task(id: loadGeneration) { await loadInitialData() }
        .onChange(of: pubkyProfile.isAdoptingRingIdentity || pubkyProfile.isRestoringSession) { _, busy in
            if !busy, screenGeneration == nil {
                loadGeneration += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProfileOperationAdmission.didReleaseOperation,
                                                        object: ProfileOperationAdmission.shared).receive(on: RunLoop.main))
        { _ in
            if screenGeneration == nil {
                loadGeneration += 1
            }
        }
    }

    // MARK: - Form Content

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(spacing: 32) {
                avatarSection
                nameInput
                CustomDivider()
                pubkyKeySection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        CustomButton(
            title: t("common__continue"),
            isLoading: isSaving
        ) {
            await saveProfile()
        }
        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("CreateProfileSave")
        .padding(.top, 16)
        .padding(.horizontal, 16)
    }

    // MARK: - Avatar Section

    private var avatarSection: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            avatarContent
        }
        .accessibilityIdentifier("CreateProfileAvatar")
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

    // MARK: - Name Input

    private var nameInput: some View {
        ProfileNameField(name: $username, accessibilityId: "CreateProfileUsername", focusesWhenEmpty: true)
    }

    // MARK: - Pubky Key Section

    private var pubkyKeySection: some View {
        VStack(spacing: 8) {
            CaptionMText(t("profile__create_pubky_display_label"), textColor: .white64)

            BodyMSBText(
                derivedPublicKey.isEmpty ? "..." : derivedPublicKey,
                textColor: .white
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ActivityIndicator(size: 32)
            BodyMText(t("profile__deriving_keys"), textColor: .white64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Logger.error("Failed to load selected image: \(error)", context: "CreateProfileView")
        }
        selectedPhotoItem = nil
    }

    // MARK: - Data Loading

    private func loadInitialData() async {
        let admission = ProfileOperationAdmission.shared
        if screenOwner == nil {
            screenOwner = pubkyProfile.removalPresentationOwner
        }
        guard let screenOwner, pubkyProfile.ownsRemovalPresentation(screenOwner) else { return }
        if screenGeneration == nil {
            guard let generation = try? admission.snapshot() else { return }
            screenGeneration = generation
        }
        guard let screenGeneration,
              (try? admission.validate(screenGeneration)) != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await admission.withOperation {
                let publicKey = try await pubkyProfile.activePublicKey()
                try admission.checkCurrent()
                guard pubkyProfile.ownsRemovalPresentation(screenOwner) else { throw PubkyServiceError.identityChanged }
                let remote = try await remoteProfile(publicKey: publicKey)
                try admission.checkCurrent()
                guard pubkyProfile.ownsRemovalPresentation(screenOwner) else { throw PubkyServiceError.identityChanged }
                derivedPublicKey = publicKey
                remoteLookupFailed = false
                existingProfile = remote
                isRestoring = remote != nil
                if let remote {
                    username = remote.name
                }
            }
        } catch {
            guard !Task.isCancelled, pubkyProfile.ownsRemovalPresentation(screenOwner),
                  (try? admission.validate(screenGeneration)) != nil else { return }
            remoteLookupFailed = true
            Logger.error("Failed to load the profile: \(error)", context: "CreateProfileView")
            app.toast(type: .error, title: t("profile__create_error_title"), description: error.localizedDescription)
        }
    }

    /// A failed existing-profile lookup must not become permission to overwrite it with empty fields.
    private func remoteProfile(publicKey: String) async throws -> PubkyProfile? {
        guard pubkyProfile.publicKey != nil || PubkyProfileManager.hasLocalSecretKey(for: publicKey) else {
            return await pubkyProfile.fetchRemoteProfile(publicKey: publicKey)
        }
        do { return try await PubkyProfileManager.resolveRemoteProfile(publicKey: publicKey) }
        catch PubkyServiceError.profileNotFound { return nil }
    }

    // MARK: - Save Profile

    private func saveProfile() async {
        guard !remoteLookupFailed else {
            await loadInitialData()
            return
        }

        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let screenOwner, let screenGeneration,
              pubkyProfile.ownsRemovalPresentation(screenOwner) else { return }
        let admission = ProfileOperationAdmission.shared

        isSaving = true
        defer { isSaving = false }

        do {
            try await admission.withSessionTransition(expected: screenGeneration) {
                guard pubkyProfile.ownsRemovalPresentation(screenOwner) else { throw PubkyServiceError.identityChanged }
                do {
                    try await pubkyProfile.createIdentity(
                        name: trimmedName,
                        bio: existingProfile?.bio ?? "",
                        links: existingProfile?.links ?? [],
                        tags: existingProfile?.tags ?? [],
                        existingImageUrl: existingProfile?.imageUrl,
                        avatarImage: avatarImage
                    )
                    try admission.checkCurrent()
                    navigation.navigate(.payContacts)
                } catch {
                    guard !Task.isCancelled, (try? admission.checkCurrent()) != nil else { throw error }
                    try pubkyProfile.schedulePresentationContext { owner, generation in
                        self.screenOwner = owner
                        self.screenGeneration = generation
                    }
                    Logger.error("Failed to save profile: \(error)", context: "CreateProfileView")
                    app.toast(type: .error, title: t("profile__create_error_title"), description: error.localizedDescription)
                }
            }
        } catch {
            // A retired screen cannot present results for its replacement identity.
        }
    }
}

// MARK: - Profile Link Input Model

struct ProfileLinkInput: Identifiable {
    let id = UUID()
    var label: String
    var url: String
}

#Preview {
    NavigationStack {
        CreateProfileView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
    }
    .preferredColorScheme(.dark)
}
