import SwiftUI

struct AddContactView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    let publicKey: String

    @State private var fetchedProfile: PubkyProfile?
    @State private var isLoading = true
    @State private var isSaving = false

    private var truncatedPublicKey: String {
        guard publicKey.count > 10 else { return publicKey }
        return "\(publicKey.prefix(4))...\(publicKey.suffix(4))"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__add_title"))
                .padding(.horizontal, 16)

            if isLoading && fetchedProfile == nil {
                loadingContent
            } else if let profile = fetchedProfile {
                resultContent(profile)
            } else {
                errorContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            await loadProfile()
        }
    }

    // MARK: - Loading State

    @State private var dashedCircleRotation: Double = 0

    @ViewBuilder
    private var loadingContent: some View {
        VStack(spacing: 0) {
            CaptionMText(truncatedPublicKey, textColor: .white64)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Circle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 80, height: 80)
                .overlay {
                    Text(String(publicKey.prefix(1)).uppercased())
                        .font(Fonts.bold(size: 28))
                        .foregroundColor(.textPrimary)
                }
                .accessibilityHidden(true)
                .padding(.bottom, 24)

            DisplayText(t("contacts__add_retrieving"), accentColor: .pubkyGreen)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("AddContactRetrievingTitle")

            Spacer()

            retrievingAnimation

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                dashedCircleRotation = 360
            }
        }
    }

    @ViewBuilder
    private var retrievingAnimation: some View {
        ZStack {
            Image("ellipse-outer-green")
                .resizable()
                .scaledToFit()
                .frame(width: 311, height: 311)
                .rotationEffect(.degrees(dashedCircleRotation))

            Image("ellipse-inner-green")
                .resizable()
                .scaledToFit()
                .frame(width: 207, height: 207)
                .rotationEffect(.degrees(-dashedCircleRotation))

            Image("contact-card")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
        }
    }

    // MARK: - Result State

    @ViewBuilder
    private func resultContent(_ profile: PubkyProfile) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    CenteredProfileHeader(
                        truncatedKey: profile.truncatedPublicKey,
                        name: profile.name,
                        bio: profile.bio,
                        imageUrl: profile.imageUrl
                    )
                    .padding(.top, 24)
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            BodySText(
                t("contacts__add_disclaimer", variables: ["name": profile.name]),
                textColor: .white50
            )
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            HStack(spacing: 16) {
                CustomButton(title: t("common__discard"), variant: .secondary) {
                    navigation.navigateBack()
                }
                .accessibilityIdentifier("AddContactDiscard")

                CustomButton(title: t("common__save"), isLoading: isSaving) {
                    await saveContact()
                }
                .disabled(isSaving)
                .accessibilityIdentifier("AddContactSave")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Error State

    @ViewBuilder
    private var errorContent: some View {
        VStack(spacing: 16) {
            Spacer()
            BodyMText(t("contacts__add_error"))
            CustomButton(title: t("profile__retry_load"), variant: .secondary) {
                await loadProfile()
            }
            .accessibilityIdentifier("AddContactRetry")
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadProfile() async {
        isLoading = true
        fetchedProfile = nil
        if let profile = await contactsManager.fetchContactProfile(publicKey: publicKey, includePlaceholder: true) {
            fetchedProfile = profile
        }
        isLoading = false
    }

    // MARK: - Save Contact

    private func saveContact() async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await contactsManager.addContact(publicKey: publicKey, existingProfile: fetchedProfile)
            app.toast(type: .success, title: t("contacts__add_success"))
            navigation.navigateBack()
        } catch {
            Logger.error("Failed to save contact: \(error)", context: "AddContactView")
            app.toast(type: .error, title: t("contacts__add_error"))
        }
    }
}

#Preview {
    NavigationStack {
        AddContactView(publicKey: "pubkyz6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(PubkyProfileManager())
    }
    .preferredColorScheme(.dark)
}
