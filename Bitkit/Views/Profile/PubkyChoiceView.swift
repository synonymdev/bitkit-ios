import SwiftUI

struct PubkyChoiceView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var contactsManager: ContactsManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedPubky: String?

    var body: some View {
        ZStack {
            backgroundIllustrations

            VStack(spacing: 0) {
                NavigationBar(title: "")
                    .overlay {
                        TitleText(t("profile__nav_title"))
                            .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 16)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        titleSection
                            .padding(.top, 20)
                            .padding(.bottom, 33)

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
        .task {
            await pubkyProfile.refreshSharedRingIdentities()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await pubkyProfile.refreshSharedRingIdentities()
            }
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 13.5) {
            DisplayText(
                t("profile__choice_title"),
                accentColor: .pubkyGreen
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            BodyMText(t("profile__choice_description"), kerning: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var optionCards: some View {
        VStack(spacing: 8) {
            createCard

            ForEach(pubkyProfile.sharedRingIdentities) { identity in
                sharedIdentityCard(identity)
            }

            if pubkyProfile.isLoadingSharedRingIdentities,
               pubkyProfile.sharedRingIdentities.isEmpty
            {
                discoveryLoadingCard
            }
        }
    }

    private var createCard: some View {
        Button {
            navigation.navigate(.createProfile)
        } label: {
            HStack(spacing: 16) {
                cardIcon

                VStack(alignment: .leading, spacing: 2) {
                    CaptionMText(t("profile__choice_new_pubky"), textColor: .white64)
                    BodyMSBText(t("profile__choice_create"), textColor: .white)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.gray6)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
        .disabled(selectedPubky != nil)
        .accessibilityIdentifier("PubkyChoiceCreate")
    }

    private func sharedIdentityCard(_ identity: SharedPubkyIdentityOption) -> some View {
        Button {
            Task {
                await useSharedIdentity(identity)
            }
        } label: {
            HStack(spacing: 16) {
                cardKeyIcon

                VStack(alignment: .leading, spacing: 2) {
                    CaptionMText(
                        PubkyPublicKeyFormat.displayTruncated(identity.reference.pubky),
                        textColor: .white64
                    )
                    BodyMSBText(identity.profile.name, textColor: .white)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if selectedPubky == identity.reference.pubky {
                    ActivityIndicator(size: 24)
                        .frame(width: 40, height: 40)
                } else {
                    PubkyContactAvatar(
                        name: identity.profile.name,
                        imageUrl: identity.profile.imageUrl,
                        size: 32
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.gray6)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
        .disabled(selectedPubky != nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("PubkyChoiceShared_\(identity.reference.pubky)")
    }

    private var discoveryLoadingCard: some View {
        HStack(spacing: 16) {
            cardKeyIcon
            ActivityIndicator(size: 20)
            BodyMSBText(t("profile__ring_loading"), textColor: .white64)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color.gray6)
        .cornerRadius(16)
        .accessibilityIdentifier("PubkyChoiceSharedLoading")
    }

    private var cardIcon: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: 40, height: 40)

            Image("user-plus")
                .resizable()
                .scaledToFit()
                .foregroundColor(.pubkyGreen)
                .frame(width: 20, height: 20)
        }
    }

    private var cardKeyIcon: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: 40, height: 40)

            Image("key")
                .resizable()
                .scaledToFit()
                .foregroundColor(.pubkyGreen)
                .frame(width: 20, height: 20)
        }
    }

    private func useSharedIdentity(_ identity: SharedPubkyIdentityOption) async {
        guard selectedPubky == nil else { return }
        selectedPubky = identity.reference.pubky
        defer { selectedPubky = nil }

        do {
            let publicKey = try await pubkyProfile.useSharedRingIdentity(identity)
            let destination = await contactsManager.destinationAfterAuthentication(
                profile: pubkyProfile.profile,
                publicKey: publicKey
            )
            navigation.path = [destination]
            pubkyProfile.finalizeAuthentication()
        } catch {
            Logger.warn("Failed to use shared Pubky Ring identity: \(error)", context: "PubkyChoiceView")
            app.toast(
                type: .error,
                title: t("profile__auth_error_title"),
                description: error.localizedDescription
            )
            await pubkyProfile.refreshSharedRingIdentities()
        }
    }

    private var backgroundIllustrations: some View {
        GeometryReader { geo in
            Image("tag-pubky")
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width * 0.64)
                .position(
                    x: geo.size.width * 0.187,
                    y: geo.size.height * 0.376 + 364
                )

            Image("keyring")
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width * 0.83)
                .opacity(0.9)
                .position(
                    x: geo.size.width * 0.751,
                    y: geo.size.height * 0.305 + 370
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
