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
            VStack(alignment: .leading, spacing: 0) {
                profileHeader(profile)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                profileBio(profile)
                    .padding(.bottom, 24)

                profileActions
                    .padding(.bottom, 24)

                profileQRCode(profile)
                    .padding(.bottom, 32)

                if !profile.links.isEmpty {
                    profileLinks(profile)
                }
            }
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Actions (copy, share, edit)

    @ViewBuilder
    private var profileActions: some View {
        HStack(spacing: 16) {
            profileActionButton(icon: "copy", accessibilityLabel: t("common__copy")) {
                if let pk = pubkyProfile.publicKey {
                    UIPasteboard.general.string = pk
                    app.toast(type: .success, title: t("common__copied"))
                }
            }
            .accessibilityIdentifier("ProfileCopy")

            profileActionButton(icon: "share", accessibilityLabel: t("common__share")) {
                shareProfile()
            }
            .accessibilityIdentifier("ProfileShare")

            profileActionButton(systemIcon: "rectangle.portrait.and.arrow.right", accessibilityLabel: t("profile__sign_out")) {
                showSignOutConfirmation = true
            }
            .disabled(isSigningOut)
            .opacity(isSigningOut ? 0.5 : 1)
            .accessibilityIdentifier("ProfileSignOut")
        }
    }

    @ViewBuilder
    private func profileActionButton(icon: String? = nil, systemIcon: String? = nil, accessibilityLabel: String,
                                     action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.gray5, .gray6],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white10, lineWidth: 1)
                            .padding(0.5)
                    )

                if let icon {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                } else if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textPrimary)
                }
            }
            .frame(width: 48, height: 48)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Header (name, key, avatar)

    @ViewBuilder
    private func profileHeader(_ profile: PubkyProfile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HeadlineText(profile.name)
                    .fixedSize(horizontal: false, vertical: true)

                BodySSBText(profile.truncatedPublicKey, textColor: .white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let imageUrl = profile.imageUrl {
                PubkyImage(uri: imageUrl, size: 64)
            } else {
                profilePlaceholder
            }
        }
    }

    @ViewBuilder
    private var profilePlaceholder: some View {
        Circle()
            .fill(Color.pubkyGreen)
            .frame(width: 64, height: 64)
            .overlay {
                Image("user-square")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.white32)
                    .frame(width: 32, height: 32)
            }
    }

    // MARK: - Bio

    @ViewBuilder
    private func profileBio(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(Fonts.regular(size: 22))
                    .foregroundColor(.white64)
                    .kerning(0.4)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CustomDivider()
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

            BodySText(t("profile__qr_scan_label", variables: ["name": profile.name]), textColor: .white)
                .multilineTextAlignment(.center)
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
            Spacer()
        }
        .padding(.horizontal, 32)
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
