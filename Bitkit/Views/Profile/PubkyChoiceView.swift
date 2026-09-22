import SwiftUI

struct PubkyChoiceView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager
    @Environment(\.scenePhase) var scenePhase

    @State private var isAuthenticating = false
    @State private var isWaitingForRing = false
    @State private var isLoadingAfterAuth = false
    @State private var showRingNotInstalledDialog = false
    @State private var ringPubkys: [String] = []
    @State private var profiles: [String: PubkyProfile] = [:]
    @State private var didLoad = false
    @State private var isAdopting = false

    private let pubkyRingAppStoreUrl = "https://apps.apple.com/app/pubky-ring/id6739356756"

    private var hasRingIdentities: Bool {
        !ringPubkys.isEmpty
    }

    static func descriptionKey(hasRingIdentities: Bool) -> String {
        hasRingIdentities ? "profile__choice_description_ring" : "profile__choice_description"
    }

    static func showsCreateCard(hasRingIdentities: Bool) -> Bool {
        !hasRingIdentities
    }

    var body: some View {
        ZStack {
            backgroundIllustrations

            VStack(spacing: 0) {
                NavigationBar(title: t("profile__nav_title"))
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 0) {
                    titleSection
                        .padding(.top, 24)
                        .padding(.bottom, 24)

                    optionCards
                }
                .padding(.horizontal, 16)

                Spacer()
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            ringPubkys = SharedPubkyKeychain.listRingIdentities()
            didLoad = true
            await loadProfiles()
        }
        .task(id: isWaitingForRing) {
            guard isWaitingForRing else { return }
            await waitForApproval()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, isWaitingForRing {
                // Ring returned to app — approval task handles completion
            }
        }
        .onChange(of: pubkyProfile.authState) { _, authState in
            authState.resetRingAuthViewStateIfNeeded(
                isAuthenticating: $isAuthenticating,
                isWaitingForRing: $isWaitingForRing,
                isLoadingAfterAuth: $isLoadingAfterAuth
            )
        }
        .alert(t("profile__ring_not_installed_title"), isPresented: $showRingNotInstalledDialog) {
            Button(t("profile__ring_download")) {
                if let url = URL(string: pubkyRingAppStoreUrl) {
                    Task { await UIApplication.shared.open(url) }
                }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("profile__ring_not_installed_description"))
        }
    }

    // MARK: - Title Section

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisplayText(
                t("profile__choice_title"),
                accentColor: .pubkyGreen
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            BodyMText(isLoadingAfterAuth
                ? t("profile__ring_loading")
                : isWaitingForRing
                ? t("profile__ring_waiting")
                : t(Self.descriptionKey(hasRingIdentities: hasRingIdentities)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Option Cards

    private var optionCards: some View {
        VStack(spacing: 8) {
            if didLoad {
                if Self.showsCreateCard(hasRingIdentities: hasRingIdentities) {
                    PubkyChoiceRow(
                        icon: "user-plus",
                        caption: t("profile__choice_create_caption"),
                        title: t("profile__choice_create"),
                        accessibilityId: "PubkyChoiceCreate"
                    ) {
                        navigation.navigate(.createProfile)
                    }
                } else {
                    ForEach(ringPubkys, id: \.self) { pubky in
                        ringRow(pubky)
                    }
                }
            }
        }
    }

    private func ringRow(_ pubky: String) -> some View {
        let truncatedKey = PubkyPublicKeyFormat.displayTruncated(pubky)
        let profile = profiles[pubky]
        let name = profile?.name ?? ""
        let title = name.isEmpty ? truncatedKey : name

        return PubkyChoiceRow(
            systemIcon: "key.fill",
            caption: truncatedKey,
            title: title,
            avatarName: title,
            avatarImageUrl: profile?.imageUrl,
            accessibilityId: "PubkyChoiceRing_\(pubky)"
        ) {
            Task { await adopt(pubky) }
        }
        .disabled(isAdopting)
    }

    private func adopt(_ pubky: String) async {
        isAdopting = true
        defer { isAdopting = false }

        do {
            guard let adopted = try await pubkyProfile.adoptRingIdentity(pubky: pubky) else {
                navigation.navigate(.createProfile)
                return
            }

            await navigateAfterAuth(publicKey: adopted.publicKey)
        } catch {
            app.toast(type: .error, title: t("profile__adopt_error_title"), description: error.localizedDescription)
        }
    }

    private func loadProfiles() async {
        let manager = pubkyProfile
        profiles = await withTaskGroup(of: (String, PubkyProfile?).self) { group in
            for pubky in ringPubkys {
                group.addTask { await (pubky, manager.fetchRemoteProfile(publicKey: pubky)) }
            }

            var loaded: [String: PubkyProfile] = [:]
            for await (pubky, profile) in group {
                loaded[pubky] = profile
            }
            return loaded
        }
    }

    // MARK: - Ring Auth

    private func startRingAuth() async {
        isAuthenticating = true

        do {
            try await pubkyProfile.startAuthentication()
            isAuthenticating = false
            isWaitingForRing = true
        } catch PubkyServiceError.ringNotInstalled {
            isAuthenticating = false
            showRingNotInstalledDialog = true
        } catch {
            isAuthenticating = false
            app.toast(type: .error, title: t("profile__auth_error_title"), description: error.localizedDescription)
        }
    }

    private func waitForApproval() async {
        do {
            let publicKey = try await pubkyProfile.completeAuthentication()
            isLoadingAfterAuth = true
            await navigateAfterAuth(publicKey: publicKey)
        } catch is CancellationError {
            return
        } catch {
            isWaitingForRing = false
            app.toast(type: .error, title: t("profile__auth_error_title"), description: error.localizedDescription)
        }
    }

    private func navigateAfterAuth(publicKey: String) async {
        let destination = await contactsManager.destinationAfterAuthentication(
            profile: pubkyProfile.profile,
            publicKey: publicKey
        )
        navigation.path = [destination]
        pubkyProfile.finalizeAuthentication()
    }

    // MARK: - Ring Waiting Card

    private var ringWaitingCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 40, height: 40)

                    ActivityIndicator(size: 20)
                }

                BodyMSBText(t(isLoadingAfterAuth ? "profile__ring_loading" : "profile__ring_waiting"), textColor: .white)

                Spacer()
            }

            if !isLoadingAfterAuth {
                Button {
                    isWaitingForRing = false
                    Task { await pubkyProfile.cancelAuthentication() }
                } label: {
                    BodySSBText(t("common__cancel"), textColor: .white64)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("PubkyChoiceCancelRing")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color.gray6)
        .cornerRadius(16)
    }

    // MARK: - Background Illustrations

    private var backgroundIllustrations: some View {
        GeometryReader { geo in
            Image("tag-pubky")
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width * 0.83)
                .position(
                    x: geo.size.width * 0.321,
                    y: geo.size.height * 0.376 + 200
                )

            Image("keyring")
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width * 0.83)
                .opacity(0.9)
                .position(
                    x: geo.size.width * 0.841,
                    y: geo.size.height * 0.305 + 200
                )
        }
        .ignoresSafeArea()
    }
}

#Preview {
    NavigationStack {
        PubkyChoiceView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
