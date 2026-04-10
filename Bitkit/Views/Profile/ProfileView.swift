import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var showSignOutConfirmation = false
    @State private var isSigningOut = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(
                title: t("profile__nav_title")
            )
            .padding(.horizontal, 16)

            if pubkyProfile.isLoadingProfile && pubkyProfile.profile == nil {
                loadingContent
            } else if let profile = pubkyProfile.profile {
                profileContent(profile)
            } else {
                emptyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            guard pubkyProfile.profile == nil else { return }
            await pubkyProfile.loadProfile()
        }
        .alert(
            t("profile__sign_out_title"),
            isPresented: $showSignOutConfirmation
        ) {
            Button(t("profile__sign_out"), role: .destructive) {
                Task { await performSignOut() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("profile__sign_out_description"))
        }
    }

    // MARK: - Profile Content

    @ViewBuilder
    private func profileContent(_ profile: PubkyProfile) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                CenteredProfileHeader(
                    truncatedKey: profile.truncatedPublicKey,
                    name: profile.name,
                    bio: profile.bio,
                    imageUrl: profile.imageUrl,
                    showDivider: false
                )
                .padding(.top, 24)
                .padding(.bottom, 24)

                profileQRCode(profile)
                    .padding(.bottom, 24)

                profileActions
                    .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 0) {
                    if !profile.links.isEmpty {
                        profileLinks(profile)
                    }

                    if !profile.tags.isEmpty {
                        profileTags(profile)
                            .padding(.top, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Actions (edit, copy, share)

    @ViewBuilder
    private var profileActions: some View {
        HStack(spacing: 16) {
            GradientCircleButton(icon: "pencil", accessibilityLabel: t("profile__edit")) {
                navigation.navigate(.editProfile)
            }
            .accessibilityIdentifier("ProfileEdit")

            GradientCircleButton(icon: "copy", accessibilityLabel: t("common__copy")) {
                if let pk = pubkyProfile.publicKey {
                    UIPasteboard.general.string = pk
                    app.toast(type: .success, title: t("common__copied"))
                }
            }
            .accessibilityIdentifier("ProfileCopy")

            GradientCircleButton(icon: "share", accessibilityLabel: t("common__share")) {
                shareProfile()
            }
            .accessibilityIdentifier("ProfileShare")
        }
    }

    // MARK: - QR Code

    @ViewBuilder
    private func profileQRCode(_ profile: PubkyProfile) -> some View {
        VStack(spacing: 12) {
            ZStack {
                QR(content: profile.publicKey)

                if let imageUrl = profile.imageUrl {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 68, height: 68)

                        PubkyImage(uri: imageUrl, size: 50)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Links / Metadata

    @ViewBuilder
    private func profileLinks(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(profile.links) { link in
                ProfileLinkRow(label: link.label, value: link.url)
            }
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private func profileTags(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("profile__create_tags_label"), textColor: .white64)

            WrappingHStack(spacing: 8) {
                ForEach(profile.tags, id: \.self) { tag in
                    Tag(tag)
                }
            }
        }
    }

    // MARK: - Loading / Empty States

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
            BodyMText(t("profile__empty_state"))
            CustomButton(title: t("profile__retry_load"), variant: .secondary) {
                await pubkyProfile.loadProfile()
            }
            .accessibilityIdentifier("ProfileRetry")
            Button(t("profile__sign_out")) {
                showSignOutConfirmation = true
            }
            .font(Fonts.regular(size: 17))
            .foregroundColor(.white64)
            .accessibilityLabel(t("profile__sign_out"))
            .accessibilityIdentifier("ProfileEmptySignOut")
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sign Out & Share

    private func performSignOut() async {
        isSigningOut = true
        await pubkyProfile.signOut()
        isSigningOut = false
    }

    private func shareProfile() {
        guard let pk = pubkyProfile.publicKey else { return }
        let activityVC = UIActivityViewController(
            activityItems: [pk],
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

// MARK: - Profile Link Row

struct ProfileLinkRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(label, textColor: .white64)

                BodySSBText(value, textColor: .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 16)

            CustomDivider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text("\(label): \(value)"))
    }
}

#Preview {
    let manager = PubkyProfileManager()
    NavigationStack {
        ProfileView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(manager)
    }
    .preferredColorScheme(.dark)
}
