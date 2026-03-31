import SwiftUI

struct PubkyRingAuthView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager
    @Environment(\.scenePhase) var scenePhase

    @State private var isAuthenticating = false
    @State private var isWaitingForRing = false
    @State private var isRingInstalled = false
    @State private var showRingNotInstalledDialog = false

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

                    if isRingInstalled {
                        if isWaitingForRing {
                            VStack(spacing: 12) {
                                CustomButton(
                                    title: t("profile__ring_waiting"),
                                    isLoading: true
                                ) {}
                                    .disabled(true)

                                Button {
                                    isWaitingForRing = false
                                    Task { await pubkyProfile.cancelAuthentication() }
                                } label: {
                                    Text(t("common__cancel"))
                                        .font(Fonts.semiBold(size: 15))
                                        .foregroundColor(.white64)
                                }
                                .accessibilityIdentifier("PubkyRingCancelAuth")
                            }
                        } else {
                            CustomButton(
                                title: t("profile__ring_authorize"),
                                isLoading: isAuthenticating
                            ) {
                                await authenticate()
                            }
                            .accessibilityIdentifier("PubkyRingAuthorize")
                        }
                    } else {
                        CustomButton(title: t("profile__ring_download")) {
                            if let url = URL(string: pubkyRingAppStoreUrl) {
                                await UIApplication.shared.open(url)
                            }
                        }
                        .accessibilityIdentifier("PubkyRingDownload")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            checkRingInstalled()
        }
        .task(id: isWaitingForRing) {
            guard isWaitingForRing else { return }
            await waitForApproval()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                checkRingInstalled()
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

    private func checkRingInstalled() {
        if let url = URL(string: "pubkyauth://check") {
            isRingInstalled = UIApplication.shared.canOpenURL(url)
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
            isRingInstalled = false
            showRingNotInstalledDialog = true
        } catch {
            isAuthenticating = false
            app.toast(type: .error, title: t("profile__auth_error_title"), description: error.localizedDescription)
        }
    }

    private func waitForApproval() async {
        do {
            try await pubkyProfile.completeAuthentication()
            isWaitingForRing = false
            await navigateAfterAuth()
        } catch is CancellationError {
            isWaitingForRing = false
            await pubkyProfile.cancelAuthentication()
        } catch {
            isWaitingForRing = false
            app.toast(type: .error, title: t("profile__auth_error_title"), description: error.localizedDescription)
        }
    }

    private func navigateAfterAuth() async {
        guard let pk = pubkyProfile.publicKey else {
            navigation.path = [.profile]
            return
        }

        let hasImportData = await contactsManager.prepareImport(profile: pubkyProfile.profile, publicKey: pk)
        navigation.path = [hasImportData ? .contactImportOverview : .payContacts]
    }
}

#Preview {
    NavigationStack {
        PubkyRingAuthView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
