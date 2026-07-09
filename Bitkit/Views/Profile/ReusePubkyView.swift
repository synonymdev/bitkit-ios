import SwiftUI

/// Shown before a Bitkit profile exists when one or more pubky identities are available in the shared
/// keychain vault (e.g. created in Pubky Ring). Offers to reuse an existing identity, or fall back to
/// the normal create/import flow.
struct ReusePubkyView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager

    @State private var adoptingPubky: String?

    private var isAdopting: Bool { adoptingPubky != nil }

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

                    identityCards

                    createNewButton
                        .padding(.top, 16)
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
            await pubkyProfile.refreshSharedIdentities()
        }
    }

    // MARK: - Title Section

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisplayText(t("profile__reuse_title"), accentColor: .pubkyGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            BodyMText(isAdopting ? t("profile__reuse_loading") : t("profile__reuse_description"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Identity Cards

    private var identityCards: some View {
        VStack(spacing: 8) {
            ForEach(pubkyProfile.availableSharedIdentities, id: \.pubky) { record in
                identityCard(record)
            }
        }
    }

    private func identityCard(_ record: SharedPubkyRecord) -> some View {
        Button {
            Task { await adopt(record) }
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 40, height: 40)

                    if adoptingPubky == record.pubky {
                        ActivityIndicator(size: 20)
                    } else {
                        Image(systemName: "key.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.pubkyGreen)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    BodyMSBText(truncated(record.pubky), textColor: .white)
                    CaptionText(t("profile__reuse_source"), textColor: .white64)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.gray6)
            .cornerRadius(16)
        }
        .disabled(isAdopting)
        .accessibilityIdentifier("ReusePubky_\(record.pubky)")
    }

    private var createNewButton: some View {
        CustomButton(
            title: t("profile__reuse_create_new"),
            variant: .tertiary,
            shouldExpand: true
        ) {
            navigation.navigate(.pubkyChoice)
        }
        .disabled(isAdopting)
        .accessibilityIdentifier("ReusePubkyCreateNew")
    }

    // MARK: - Actions

    private func adopt(_ record: SharedPubkyRecord) async {
        guard !isAdopting else { return }
        adoptingPubky = record.pubky

        do {
            try await pubkyProfile.adoptSharedIdentity(record)
            if let publicKey = pubkyProfile.publicKey {
                await navigateAfterAuth(publicKey: publicKey)
            }
        } catch {
            adoptingPubky = nil
            app.toast(type: .error, title: t("profile__reuse_error_title"), description: error.localizedDescription)
        }
    }

    private func navigateAfterAuth(publicKey: String) async {
        let destination = await contactsManager.destinationAfterAuthentication(
            profile: pubkyProfile.profile,
            publicKey: publicKey
        )
        navigation.path = [destination]
    }

    private func truncated(_ pubky: String) -> String {
        guard pubky.count > 20 else { return pubky }
        return "\(pubky.prefix(10))…\(pubky.suffix(6))"
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
        ReusePubkyView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
