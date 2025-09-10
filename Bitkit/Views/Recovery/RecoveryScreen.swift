import SwiftUI

struct RecoveryScreen: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var session: SessionManager

    @Binding var navigationPath: [RecoveryRoute]
    @State private var locked = true
    @State private var showPinCheck = false
    @State private var showWipeAlert = false
    @State private var pendingAction: PendingAction?

    enum PendingAction {
        case showSeed
        case wipeApp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("security__recovery"), showBackButton: false, showMenuButton: false)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    BodyMText(t("security__recovery_text"))
                        .padding(.bottom, 32)

                    VStack(spacing: 16) {
                        CustomButton(
                            title: t("lightning__export_logs"),
                            variant: .secondary,
                            isDisabled: locked
                        ) {
                            onExportLogs()
                        }

                        CustomButton(
                            title: t("security__display_seed"),
                            variant: .secondary,
                            isDisabled: locked || wallet.walletExists != true
                        ) {
                            onShowSeed()
                        }

                        CustomButton(
                            title: t("security__contact_support"),
                            variant: .secondary,
                            isDisabled: locked
                        ) {
                            onContactSupport()
                        }

                        CustomButton(
                            title: t("security__wipe_app"),
                            variant: .secondary,
                            isDisabled: locked
                        ) {
                            onWipeApp()
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .overlay {
            if showPinCheck {
                PinCheckView(
                    title: t("security__pin_enter"),
                    explanation: "",
                    onCancel: {
                        pendingAction = nil
                        showPinCheck = false
                    },
                    onPinVerified: { _ in
                        showPinCheck = false
                        handlePinVerified()
                    }
                )
            }
        }
        .alert(isPresented: $showWipeAlert) {
            Alert(
                title: Text(t("security__reset_dialog_title")),
                message: Text(t("security__reset_dialog_desc")),
                primaryButton: .destructive(Text(t("security__reset_confirm"))) {
                    onWipeAppConfirmed()
                },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            // Avoid accidentally pressing a button
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                locked = false
            }
        }
    }

    // MARK: - Actions

    private func onExportLogs() {
        Task {
            guard let zipURL = LogService.shared.zipLogs() else {
                app.toast(type: .error, title: "Error", description: "Failed to create log zip file")
                return
            }

            // Present share sheet
            await MainActor.run {
                let activityViewController = UIActivityViewController(
                    activityItems: [zipURL],
                    applicationActivities: nil
                )

                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first
                {
                    window.rootViewController?.present(activityViewController, animated: true)
                }
            }
        }
    }

    private func onShowSeed() {
        // Check if PIN is enabled and show authentication if needed
        if settings.pinEnabled {
            pendingAction = .showSeed
            showPinCheck = true
        } else {
            navigationPath.append(.mnemonic)
        }
    }

    private func onContactSupport() {
        let supportLink = createSupportLink()
        let success = openURL(supportLink)

        if !success {
            // Fallback to web contact page
            if let fallbackURL = URL(string: "https://synonym.to/contact") {
                UIApplication.shared.open(fallbackURL)
            }
        }
    }

    private func createSupportLink() -> String {
        let subject = "Bitkit Support"
        var body = ""

        // Get app version info
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

        // Get platform info
        body += "Platform: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n"
        body += "Version: \(appVersion) (\(buildNumber))\n"

        // Get LDK node info
        let nodeId = LightningService.shared.nodeId
        if let nodeId {
            body += "LDK node ID: \(nodeId)\n"
        }

        // URL encode the subject and body
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body

        return "mailto:support@synonym.to?subject=\(encodedSubject)&body=\(encodedBody)"
    }

    private func openURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }

        Task { @MainActor in
            await UIApplication.shared.open(url)
        }

        return true
    }

    private func onWipeApp() {
        // Check if PIN is enabled and show authentication if needed
        if settings.pinEnabled {
            pendingAction = .wipeApp
            showPinCheck = true
        } else {
            showWipeAlert = true
        }
    }

    private func handlePinVerified() {
        switch pendingAction {
        case .showSeed:
            navigationPath.append(.mnemonic)
        case .wipeApp:
            showWipeAlert = true
        case .none:
            break
        }
        pendingAction = nil
    }

    private func onWipeAppConfirmed() {
        Task {
            do {
                try await AppReset.wipe(
                    app: app,
                    wallet: wallet,
                    session: session
                )
            } catch {
                app.toast(
                    type: .error,
                    title: "Wipe Failed",
                    description: "Bitkit was unable to reset your wallet data. Please try again."
                )
            }
        }

        showWipeAlert = false
    }
}
