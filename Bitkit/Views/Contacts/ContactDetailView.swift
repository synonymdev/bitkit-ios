import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager

    let publicKey: String

    @State private var profile: PubkyProfile?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__detail_title"))
                .padding(.horizontal, 16)

            if isLoading && profile == nil {
                loadingContent
            } else if let profile {
                contactBody(profile)
            } else {
                emptyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            if let cached = contactsManager.contacts.first(where: { $0.publicKey == publicKey }) {
                profile = cached.profile
            }
            await loadContact()
        }
    }

    // MARK: - Contact Body

    @ViewBuilder
    private func contactBody(_ profile: PubkyProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                contactHeader(profile)
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                contactBio(profile)
                    .padding(.bottom, 24)

                contactActions
                    .padding(.bottom, 32)

                if !profile.links.isEmpty {
                    linksSection(profile)
                }
            }
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Header (name, key, avatar)

    @ViewBuilder
    private func contactHeader(_ profile: PubkyProfile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HeadlineText(profile.name)
                    .fixedSize(horizontal: false, vertical: true)

                BodySSBText(profile.truncatedPublicKey, textColor: .white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let imageUrl = profile.imageUrl {
                    PubkyImage(uri: imageUrl, size: 64)
                } else {
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
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - Bio

    @ViewBuilder
    private func contactBio(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(Fonts.regular(size: 17))
                    .foregroundColor(.white64)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CustomDivider()
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var contactActions: some View {
        HStack(spacing: 16) {
            actionButton(icon: "copy", accessibilityLabel: t("common__copy")) {
                UIPasteboard.general.string = publicKey
                app.toast(type: .success, title: t("common__copied"))
            }
            .accessibilityIdentifier("ContactCopy")

            actionButton(icon: "share", accessibilityLabel: t("common__share")) {
                shareContact()
            }
            .accessibilityIdentifier("ContactShare")
        }
    }

    @ViewBuilder
    private func actionButton(icon: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
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

                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .frame(width: 48, height: 48)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Links / Metadata

    @ViewBuilder
    private func linksSection(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(profile.links) { link in
                ProfileLinkRow(label: link.label, value: link.url)
            }
        }
    }

    // MARK: - Loading & Empty States

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
            BodyMText(t("contacts__detail_empty_state"))
            CustomButton(title: t("profile__retry_load"), variant: .secondary) {
                await loadContact()
            }
            .accessibilityIdentifier("ContactRetry")
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadContact() async {
        isLoading = true
        if let freshProfile = await contactsManager.fetchContactProfile(publicKey: publicKey) {
            profile = freshProfile
        } else {
            if profile == nil {
                profile = PubkyProfile.placeholder(publicKey: publicKey)
            }
            app.toast(type: .error, title: t("contacts__error_loading"))
        }
        isLoading = false
    }

    // MARK: - Share

    private func shareContact() {
        let activityVC = UIActivityViewController(
            activityItems: [publicKey],
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

#Preview {
    NavigationStack {
        ContactDetailView(publicKey: "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
