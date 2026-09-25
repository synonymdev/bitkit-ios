import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var showSignOutConfirmation = false
    @State private var showAddTagSheet = false
    @State private var isUpdatingTags = false
    @State private var isSigningOut = false
    @State private var copiedPublicKey: String?
    @State private var hideCopiedPopupTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let profile = pubkyProfile.profile {
                profileContent(profile)
            } else {
                VStack(spacing: 0) {
                    navigationBar

                    if pubkyProfile.isLoadingProfile {
                        loadingContent
                    } else {
                        emptyContent
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let copiedPublicKey {
                ClipboardCopyPopup(title: t("profile__pubky_copied"), value: copiedPublicKey)
                    .accessibilityIdentifier("ProfilePubkyCopiedToast")
                    .onTapGesture { hideCopiedPopup() }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copiedPublicKey)
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

    private var navigationBar: some View {
        NavigationBar(title: t("profile__nav_title"))
            .padding(.horizontal, 16)
    }

    private func profileContent(_ profile: PubkyProfile) -> some View {
        InsetHeaderScrollView(header: { navigationBar }) {
            VStack(spacing: 0) {
                CenteredProfileHeader(
                    truncatedKey: profile.truncatedPublicKey,
                    name: profile.name,
                    bio: profile.bio,
                    imageUrl: profile.imageUrl,
                    showDivider: false,
                    nameAccessibilityIdentifier: "ProfileViewName",
                    notesAccessibilityIdentifier: "ProfileViewNotes"
                )
                .padding(.top, 16)
                .padding(.bottom, 16)

                profileQRCode(profile)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)

                profileActions
                    .padding(.bottom, 16)

                CustomDivider()

                VStack(alignment: .leading, spacing: 0) {
                    if !profile.links.isEmpty {
                        profileLinks(profile)
                    }

                    profileTags(profile)
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showAddTagSheet) {
            AddProfileTagSheet { tag in
                addTag(tag, to: profile)
            }
        }
    }

    // MARK: - Actions (edit, copy, share)

    private var profileActions: some View {
        HStack(spacing: 16) {
            GradientCircleButton(icon: "pencil-regular", accessibilityLabel: t("profile__edit")) {
                navigation.navigate(.editProfile)
            }
            .accessibilityIdentifier("ProfileEdit")

            GradientCircleButton(icon: "copy-simple", accessibilityLabel: t("common__copy")) {
                if let pk = pubkyProfile.publicKey {
                    copyPublicKey(pk)
                }
            }
            .accessibilityIdentifier("ProfileCopy")

            GradientCircleButton(icon: "share-regular", accessibilityLabel: t("common__share")) {
                shareProfile()
            }
            .accessibilityIdentifier("ProfileShare")
        }
    }

    // MARK: - QR Code

    private func copyPublicKey(_ publicKey: String) {
        UIPasteboard.general.string = publicKey
        Haptics.notify(.success)
        copiedPublicKey = publicKey

        hideCopiedPopupTask?.cancel()
        hideCopiedPopupTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            copiedPublicKey = nil
        }
    }

    private func hideCopiedPopup() {
        hideCopiedPopupTask?.cancel()
        copiedPublicKey = nil
    }

    private func profileQRCode(_ profile: PubkyProfile) -> some View {
        Button {
            copyPublicKey(profile.publicKey)
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    // QR attaches its own tap gesture, which swallows the button tap unless it gets the action too
                    QR(content: profile.publicKey) {
                        copyPublicKey(profile.publicKey)
                    }

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
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .accessibilityLabel(t("common__copy"))
        .accessibilityIdentifier("ProfileQRCode")
    }

    // MARK: - Links

    private func profileLinks(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(profile.links.enumerated()), id: \.element.id) { index, link in
                ProfileLinkRow(label: link.label, value: link.url, linkIndex: index)
            }
        }
    }

    // MARK: - Tags

    private func profileTags(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("profile__create_tags_label"), textColor: .white64)
                .accessibilityIdentifier("ProfileViewTagsHeader")

            if !profile.tags.isEmpty {
                WrappingHStack(spacing: 8) {
                    ForEach(profile.tags, id: \.self) { tag in
                        Tag(tag, icon: .close, onDelete: {
                            updateTags(profile.tags.filter { $0 != tag }, profile: profile)
                        })
                    }
                }
            }

            IconActionButton(
                icon: "tag",
                title: t("profile__create_add_tag"),
                accessibilityId: "ProfileAddTag"
            ) {
                showAddTagSheet = true
            }
        }
        .disabled(isUpdatingTags)
    }

    private func addTag(_ tag: String, to profile: PubkyProfile) {
        guard !profile.tags.contains(tag) else { return }
        updateTags(profile.tags + [tag], profile: profile)
    }

    private func updateTags(_ tags: [String], profile: PubkyProfile) {
        guard !isUpdatingTags else { return }
        isUpdatingTags = true

        Task {
            defer { isUpdatingTags = false }

            do {
                try await pubkyProfile.saveProfile(
                    name: profile.name,
                    bio: profile.bio,
                    links: profile.links,
                    tags: tags
                )
            } catch {
                Logger.error("Failed to update profile tags: \(error)", context: "ProfileView")
                app.toast(type: .error, title: t("profile__edit_error_title"), description: error.localizedDescription)
            }
        }
    }

    // MARK: - Loading / Empty States

    private var loadingContent: some View {
        VStack {
            Spacer()
            ActivityIndicator(size: 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        do {
            try await pubkyProfile.signOut()
        } catch {
            app.toast(type: .error, title: t("profile__sign_out_title"), description: error.localizedDescription)
        }
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
    @Environment(\.openURL) private var openURL

    let label: String
    let value: String
    let linkIndex: Int

    /// Link values are free text, so only values that look like a web address, email or phone number open.
    /// A bare number counts as a phone number only in international format or under a phone label,
    /// so dates, IP addresses and other numeric text stay plain.
    static func destination(for value: String, label: String = "") -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("+") || isPhoneLabel(label), let phoneURL = phoneDestination(for: trimmed) {
            return phoneURL
        }

        if trimmed.lowercased().hasPrefix("tel:") {
            return phoneDestination(for: String(trimmed.dropFirst(4)))
        }

        guard !trimmed.contains(" ") else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "tel"].contains(scheme)
        {
            return url
        }

        if trimmed.contains("@"), trimmed.contains(".") {
            return URL(string: "mailto:\(trimmed)")
        }

        if let url = URL(string: "https://\(trimmed)"), let host = url.host, host.contains("."),
           let topLevelDomain = host.split(separator: ".").last, topLevelDomain.contains(where: \.isLetter)
        {
            return url
        }

        return nil
    }

    private static let phoneLabels: Set<String> = ["phone", "tel", "telephone", "mobile", "cell"]

    private static func isPhoneLabel(_ label: String) -> Bool {
        phoneLabels.contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static let phoneCharacters = CharacterSet(charactersIn: "+0123456789 -().")

    private static func phoneDestination(for value: String) -> URL? {
        guard value.unicodeScalars.allSatisfy(phoneCharacters.contains) else { return nil }
        let digits = value.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        let number = value.hasPrefix("+") ? "+\(digits)" : digits
        return URL(string: "tel:\(number)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let destination = Self.destination(for: value, label: label) {
                Button {
                    openURL(destination)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
            } else {
                rowContent
            }

            CustomDivider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(label, textColor: .white64)
                .accessibilityIdentifier("ProfileLinkLabel_\(linkIndex)")

            BodySSBText(value, textColor: .white)
                .accessibilityIdentifier("ProfileLinkValue_\(linkIndex)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
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
