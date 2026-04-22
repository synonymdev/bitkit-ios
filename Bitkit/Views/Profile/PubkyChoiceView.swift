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

    private let pubkyRingAppStoreUrl = "https://apps.apple.com/app/pubky-ring/id6739356756"

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
        .task(id: isWaitingForRing) {
            guard isWaitingForRing else { return }
            await waitForApproval()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, isWaitingForRing {
                // Ring returned to app — approval task handles completion
            }
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
                : isWaitingForRing ? t("profile__ring_waiting") : t("profile__choice_description"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Option Cards

    private var optionCards: some View {
        VStack(spacing: 8) {
            choiceCard(
                icon: "user-plus",
                title: t("profile__choice_create"),
                accessibilityId: "PubkyChoiceCreate"
            ) {
                navigation.navigate(.createProfile)
            }
            .disabled(isAuthenticating || isWaitingForRing || isLoadingAfterAuth)

            if isWaitingForRing || isLoadingAfterAuth {
                ringWaitingCard
            } else {
                choiceCard(
                    systemIcon: "key.fill",
                    title: t("profile__choice_import"),
                    isLoading: isAuthenticating,
                    accessibilityId: "PubkyChoiceImport"
                ) {
                    await startRingAuth()
                }
                .disabled(isAuthenticating)
            }
        }
    }

    private func choiceCard(
        icon: String? = nil,
        systemIcon: String? = nil,
        title: String,
        isLoading: Bool = false,
        accessibilityId: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 40, height: 40)

                    if isLoading {
                        ActivityIndicator(size: 20)
                    } else if let icon {
                        Image(icon)
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.pubkyGreen)
                            .frame(width: 20, height: 20)
                    } else if let systemIcon {
                        Image(systemName: systemIcon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.pubkyGreen)
                    }
                }

                BodyMSBText(title, textColor: .white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(Color.gray6)
            .cornerRadius(16)
        }
        .accessibilityIdentifier(accessibilityId)
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
            isWaitingForRing = false
            await pubkyProfile.cancelAuthentication()
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
