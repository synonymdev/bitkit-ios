import SwiftUI

struct PubkyRingAuthView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var isAuthenticating = false
    @State private var isWaitingForRing = false
    @State private var showRingNotInstalledAlert = false

    private let pubkyRingAppStoreUrl = "https://apps.apple.com/app/pubky-ring/id6739356756"

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Image("tag-pubky")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * 0.83)
                    .position(
                        x: geo.size.width * 0.321,
                        y: geo.size.height * 0.376
                    )

                Image("keyring")
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * 0.83)
                    .opacity(0.9)
                    .position(
                        x: geo.size.width * 0.841,
                        y: geo.size.height * 0.305
                    )
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                NavigationBar(title: t("profile__nav_title"))
                    .padding(.horizontal, 16)

                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    Image("pubky-ring-logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 8) {
                        DisplayText(
                            t("profile__ring_auth_title"),
                            accentColor: .pubkyGreen
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                        BodyMText(isWaitingForRing ? t("profile__ring_waiting") : t("profile__ring_auth_description"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                        .frame(height: 24)

                    HStack(spacing: 16) {
                        CustomButton(title: t("profile__ring_download"), variant: .secondary) {
                            if let url = URL(string: pubkyRingAppStoreUrl) {
                                await UIApplication.shared.open(url)
                            }
                        }
                        .accessibilityIdentifier("PubkyRingDownload")

                        CustomButton(
                            title: t("profile__ring_authorize"),
                            isLoading: isAuthenticating
                        ) {
                            await authenticate()
                        }
                        .accessibilityIdentifier("PubkyRingAuthorize")
                    }
                }
                .padding(.horizontal, 32)
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
        .alert(
            t("profile__ring_not_installed_title"),
            isPresented: $showRingNotInstalledAlert
        ) {
            Button(t("profile__ring_download")) {
                if let url = URL(string: pubkyRingAppStoreUrl) {
                    UIApplication.shared.open(url)
                }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("profile__ring_not_installed_description"))
        }
    }

    private func authenticate() async {
        if isWaitingForRing {
            isWaitingForRing = false
            await pubkyProfile.cancelAuthentication()
        }

        isAuthenticating = true

        do {
            try await pubkyProfile.startAuthentication()
            isAuthenticating = false
            isWaitingForRing = true
        } catch PubkyServiceError.ringNotInstalled {
            isAuthenticating = false
            showRingNotInstalledAlert = true
        } catch {
            isAuthenticating = false
            app.toast(type: .error, title: t("profile__auth_error_title"), description: error.localizedDescription)
        }
    }

    private func waitForApproval() async {
        do {
            try await pubkyProfile.completeAuthentication()
            isWaitingForRing = false
            if navigation.activeDrawerMenuItem == .profile {
                navigation.path = []
            } else {
                navigation.path = [.profile]
            }
        } catch is CancellationError {
            isWaitingForRing = false
        } catch {
            isWaitingForRing = false
            app.toast(type: .error, title: t("profile__auth_error_title"), description: error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack {
        PubkyRingAuthView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
    }
    .preferredColorScheme(.dark)
}
