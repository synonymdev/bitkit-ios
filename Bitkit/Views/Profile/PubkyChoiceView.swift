import SwiftUI

struct PubkyChoiceView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var ringPubkys: [String] = []
    @State private var ringProfiles: [String: PubkyProfile] = [:]
    @State private var didLoad = false
    @State private var adoptingPubky: String?
    @State private var loadTask: Task<Void, Never>?

    private var hasRingIdentities: Bool {
        !ringPubkys.isEmpty
    }

    static func descriptionKey(hasRingIdentities: Bool) -> String {
        hasRingIdentities ? "profile__choice_description_ring" : "profile__choice_description"
    }

    static func showsCreateCard(hasRingIdentities: Bool) -> Bool {
        !hasRingIdentities
    }

    /// Equals the manager's row profiles, so a row whose lookup now finds nothing drops its old name and avatar. While an
    /// adoption runs it only adds: adopting clears the manager's cache while this screen is still up, and rows must not
    /// flash back to bare keys before navigation.
    static func mirroredRingProfiles(
        _ shown: [String: PubkyProfile],
        found: [String: PubkyProfile],
        isAdopting: Bool
    ) -> [String: PubkyProfile] {
        guard isAdopting else { return found }
        return shown.merging(found) { _, latest in latest }
    }

    /// Only the other rows' lookups stop, since they would compete with sign-in while the tapped row's can still land in
    /// time to be reused. A failed adopt reloads the rows so none is left on a bare key.
    @MainActor
    static func adoptRingIdentity(
        _ pubky: String,
        pubkyProfile: PubkyProfileManager,
        reloadRows: () -> Void
    ) async throws -> PubkyProfile? {
        pubkyProfile.cancelRingIdentityLookups(except: pubky)
        do {
            return try await pubkyProfile.adoptRingIdentity(pubky: pubky)
        } catch {
            reloadRows()
            throw error
        }
    }

    var body: some View {
        ZStack {
            backgroundIllustrations

            VStack(spacing: 0) {
                NavigationBar(title: t("profile__nav_title"))
                    .padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        titleSection
                            .padding(.top, 24)
                            .padding(.bottom, 24)

                        optionCards
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .onAppear(perform: reloadIdentities)
        .onDisappear(perform: cancelLoad)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            pubkyProfile.forgetRingIdentityMisses()
            guard adoptingPubky == nil else { return }
            reloadIdentities()
        }
        .onReceive(pubkyProfile.$ringIdentityProfiles) { found in
            ringProfiles = Self.mirroredRingProfiles(ringProfiles, found: found, isAdopting: pubkyProfile.isAdoptingRingIdentity)
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

            BodyMText(t(Self.descriptionKey(hasRingIdentities: hasRingIdentities)))
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
        let profile = PubkyPublicKeyFormat.normalized(pubky).flatMap { ringProfiles[$0] }
        let name = profile?.name ?? ""
        let title = name.isEmpty ? truncatedKey : name

        return PubkyChoiceRow(
            systemIcon: "key.fill",
            caption: truncatedKey,
            title: title,
            avatarName: title,
            avatarImageUrl: profile?.imageUrl,
            isLoading: adoptingPubky == pubky,
            accessibilityId: "PubkyChoiceRing_\(pubky)"
        ) {
            startAdopting(pubky)
        }
        .disabled(adoptingPubky != nil)
    }

    private func startAdopting(_ pubky: String) {
        guard adoptingPubky == nil else { return }
        adoptingPubky = pubky
        Task { await adopt(pubky) }
    }

    private func adopt(_ pubky: String) async {
        defer { adoptingPubky = nil }

        do {
            guard let adopted = try await Self.adoptRingIdentity(pubky, pubkyProfile: pubkyProfile, reloadRows: reloadIdentities) else {
                navigation.navigate(.createProfile)
                return
            }

            let destination = await contactsManager.destinationAfterAuthentication(
                profile: pubkyProfile.profile,
                publicKey: adopted.publicKey
            )
            navigation.path = [destination]
        } catch is CancellationError {
            return
        } catch {
            app.toast(type: .error, title: t("profile__adopt_error_title"), description: error.localizedDescription)
        }
    }

    private func reloadIdentities() {
        loadTask?.cancel()
        ringPubkys = SharedPubkyKeychain.listRingIdentities()
        didLoad = true

        let pubkys = ringPubkys
        loadTask = Task { await pubkyProfile.loadRingIdentityProfiles(pubkys) }
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Background Illustrations

    private var backgroundIllustrations: some View {
        GeometryReader { geo in
            Image("keyring")
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width * 0.83)
                .opacity(0.9)
                .position(
                    x: geo.size.width * 0.756,
                    y: geo.size.height * 0.753
                )

            Image("tag-pubky")
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width * 0.736)
                .position(
                    x: geo.size.width * 0.125,
                    y: geo.size.height * 0.839
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
