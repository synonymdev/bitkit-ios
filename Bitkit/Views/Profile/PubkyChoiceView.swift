import SwiftUI

struct PubkyChoiceView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var ringPubkys: [String] = []
    @State private var profiles: [String: PubkyProfile] = [:]
    @State private var didLoad = false
    @State private var isAdopting = false

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
        .task { await loadIdentities() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadIdentities() }
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

            let destination = await contactsManager.destinationAfterAuthentication(
                profile: pubkyProfile.profile,
                publicKey: adopted.publicKey
            )
            navigation.path = [destination]
        } catch {
            app.toast(type: .error, title: t("profile__adopt_error_title"), description: error.localizedDescription)
        }
    }

    private func loadIdentities() async {
        ringPubkys = SharedPubkyKeychain.listRingIdentities()
        didLoad = true
        profiles = profiles.filter { ringPubkys.contains($0.key) }

        let manager = pubkyProfile
        await withTaskGroup(of: (String, PubkyProfile?).self) { group in
            for pubky in ringPubkys where profiles[pubky] == nil {
                group.addTask { await (pubky, manager.fetchRemoteProfile(publicKey: pubky)) }
            }

            for await (pubky, profile) in group {
                profiles[pubky] = profile
            }
        }
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
