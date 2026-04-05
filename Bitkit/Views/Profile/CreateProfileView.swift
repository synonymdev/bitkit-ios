import PhotosUI
import SwiftUI

struct CreateProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var derivedPublicKey: String = ""
    @State private var username: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isRestoring = false
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
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            await loadInitialData()
        }
    }

    // MARK: - Form Content

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                avatarSection
                    .padding(.top, 32)
                    .padding(.bottom, 24)

                nameInput
                    .padding(.bottom, 16)

                CustomDivider()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                pubkyKeySection
                    .padding(.bottom, 24)
            }
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

    @ViewBuilder
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
                .frame(width: 100, height: 100)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.gray5)
                .frame(width: 100, height: 100)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(.white32)
                }
        }
    }

    // MARK: - Name Input

    @ViewBuilder
    private var nameInput: some View {
        SwiftUI.TextField(
            t("profile__create_name_placeholder"),
            text: $username
        )
        .font(Fonts.black(size: 44))
        .kerning(-1)
        .textCase(.uppercase)
        .multilineTextAlignment(.center)
        .foregroundColor(.textPrimary)
        .padding(.horizontal, 32)
        .accessibilityIdentifier("CreateProfileUsername")
    }

    // MARK: - Pubky Key Section

    @ViewBuilder
    private var pubkyKeySection: some View {
        VStack(spacing: 8) {
            CaptionMText(t("profile__create_pubky_display_label"), textColor: .white64)

            BodySText(
                derivedPublicKey.isEmpty ? "..." : derivedPublicKey,
                textColor: .white
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Loading

    @ViewBuilder
    private var loadingView: some View {
        VStack {
            Spacer()
            ActivityIndicator(size: 32)
            Spacer()
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
        isLoading = true
        defer { isLoading = false }

        do {
            let (publicKey, _) = try await pubkyProfile.deriveKeys()
            derivedPublicKey = publicKey

            // Restore existing profile if one is found on the network
            if let remote = await pubkyProfile.fetchRemoteProfile(publicKey: publicKey) {
                username = remote.name
                existingProfile = remote
                isRestoring = true
            }
        } catch {
            Logger.error("Failed to derive pubky keys: \(error)", context: "CreateProfileView")
            app.toast(type: .error, title: t("profile__create_error_title"), description: error.localizedDescription)
            navigation.navigateBack()
        }
    }

    // MARK: - Save Profile

    private func saveProfile() async {
        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            try await pubkyProfile.createIdentity(
                name: trimmedName,
                bio: existingProfile?.bio ?? "",
                links: existingProfile?.links ?? [],
                tags: existingProfile?.tags ?? [],
                avatarImage: avatarImage
            )
            navigation.navigate(.payContacts)
        } catch {
            Logger.error("Failed to save profile: \(error)", context: "CreateProfileView")
            app.toast(type: .error, title: t("profile__create_error_title"), description: error.localizedDescription)
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
