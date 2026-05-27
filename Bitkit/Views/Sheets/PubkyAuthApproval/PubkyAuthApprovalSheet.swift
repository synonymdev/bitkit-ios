import SwiftUI

// MARK: - Config & Sheet Item

enum PubkyApprovalLocalAuthMode: Equatable {
    case authCheck
    case biometrics
    case none
}

func resolvePubkyApprovalLocalAuthMode(
    isPinEnabled: Bool,
    isBiometricEnabled: Bool,
    isBiometrySupported: Bool
) -> PubkyApprovalLocalAuthMode {
    if isPinEnabled {
        return .authCheck
    }

    if isBiometricEnabled, isBiometrySupported {
        return .biometrics
    }

    return .none
}

struct PubkyAuthApprovalConfig {
    let authUrl: String
    let request: PubkyAuthRequest
}

struct PubkyAuthApprovalSheetItem: SheetItem {
    let id: SheetID = .pubkyAuthApproval
    let size: SheetSize = .large
    let authUrl: String
    let request: PubkyAuthRequest
}

// MARK: - Sheet View

struct PubkyAuthApprovalSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var settings: SettingsViewModel

    let config: PubkyAuthApprovalSheetItem

    @State private var state: ApprovalState = .authorize
    @State private var isShowingAuthCheck = false

    private enum ApprovalState {
        case authorize
        case authorizing
        case success
    }

    private var headerTitle: String {
        state == .success ? t("pubky_auth__success_title") : t("pubky_auth__title")
    }

    var body: some View {
        Sheet(id: .pubkyAuthApproval, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: headerTitle, showBackButton: true)

                switch state {
                case .authorize:
                    authorizeContent
                case .authorizing:
                    authorizingContent
                case .success:
                    successContent
                }
            }
            .padding(.horizontal, 16)
        }
        .fullScreenCover(isPresented: $isShowingAuthCheck) {
            AuthCheck(
                onCancel: {
                    isShowingAuthCheck = false
                },
                onPinVerified: {
                    isShowingAuthCheck = false
                    Task {
                        await confirmAuthorize()
                    }
                }
            )
        }
    }

    // MARK: - Authorize State (Screen 3)

    private var authorizeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            descriptionText
                .padding(.bottom, 32)

            permissionsSection
                .padding(.bottom, 16)

            Spacer()

            trustWarning
                .padding(.bottom, 16)

            profileCard
                .padding(.bottom, 24)

            HStack(spacing: 16) {
                CustomButton(title: t("common__cancel"), variant: .secondary) {
                    sheets.hideSheet()
                }
                .accessibilityIdentifier("PubkyAuthCancel")

                CustomButton(title: t("pubky_auth__title")) {
                    await onAuthorize()
                }
                .accessibilityIdentifier("PubkyAuthAuthorize")
            }
        }
    }

    // MARK: - Authorizing State (Screen 4)

    private var authorizingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            descriptionText
                .padding(.bottom, 32)

            permissionsSection
                .padding(.bottom, 16)

            Spacer()

            trustWarning
                .padding(.bottom, 16)

            profileCard
                .padding(.bottom, 24)

            CustomButton(title: t("pubky_auth__authorizing"), isLoading: true) {}
                .disabled(true)
        }
    }

    // MARK: - Success State (Screen 5)

    private var successContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            successDescriptionText
                .padding(.bottom, 16)

            Spacer()

            Image("check")
                .resizable()
                .scaledToFit()
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)

            Spacer()

            CustomButton(title: t("common__ok")) {
                sheets.hideSheet()
            }
            .accessibilityIdentifier("PubkyAuthOK")
        }
    }

    // MARK: - Shared Components

    private var serviceText: String {
        config.request.serviceNames.joined(separator: " and ")
    }

    private var descriptionText: some View {
        BodyMText(
            t("pubky_auth__description_prefix") + "<accent>" + serviceText + "</accent>" + t("pubky_auth__description_suffix"),
            accentColor: .textPrimary,
            accentFont: Fonts.bold
        )
        .lineSpacing(4)
    }

    @ViewBuilder
    private var successDescriptionText: some View {
        let truncatedKey = pubkyProfile.profile?.truncatedPublicKey ?? ""
        BodyMText(
            t("pubky_auth__success_prefix") + "<accent>" + truncatedKey + "</accent>"
                + t("pubky_auth__success_middle") + "<accent>" + serviceText + "</accent>"
                + t("pubky_auth__success_suffix"),
            accentColor: .textPrimary,
            accentFont: Fonts.bold
        )
        .lineSpacing(4)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("pubky_auth__requested_permissions"), textColor: .white64)

            ForEach(Array(config.request.permissions.enumerated()), id: \.offset) { _, permission in
                permissionRow(permission)
            }

            CustomDivider(color: .white10)
        }
    }

    private func permissionRow(_ permission: PubkyAuthPermission) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 14))
                .foregroundColor(.white)

            BodySSBText(permission.path)
                .lineLimit(1)

            Spacer()

            CaptionMText(permission.displayAccess, textColor: .gray1)
        }
    }

    private var trustWarning: some View {
        BodySText(t("pubky_auth__trust_warning"))
            .lineSpacing(4)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CaptionMText(
                pubkyProfile.profile?.truncatedPublicKey ?? "",
                textColor: .white64
            )

            HStack(alignment: .top, spacing: 16) {
                HeadlineText(pubkyProfile.displayName ?? "")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let imageUri = pubkyProfile.displayImageUri {
                    PubkyImage(uri: imageUri, size: 64)
                } else {
                    Circle()
                        .fill(Color.pubkyGreen)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image("user-square")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.white32)
                                .frame(width: 32, height: 32)
                        }
                }
            }
        }
        .padding(24)
        .background(Color.gray6)
        .cornerRadius(16)
    }

    // MARK: - Actions

    @MainActor
    private func onAuthorize() async {
        switch resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: settings.pinEnabled,
            isBiometricEnabled: settings.useBiometrics,
            isBiometrySupported: BiometricAuth.isAvailable
        ) {
        case .authCheck:
            isShowingAuthCheck = true
        case .biometrics:
            await authorizeWithBiometrics()
        case .none:
            await confirmAuthorize()
        }
    }

    @MainActor
    private func authorizeWithBiometrics() async {
        let biometricResult = await BiometricAuth.authenticate()

        switch biometricResult {
        case .success:
            await confirmAuthorize()
        case .cancelled:
            return
        case let .failed(message):
            app.toast(type: .error, title: t("pubky_auth__biometric_failed"), description: message)
        }
    }

    @MainActor
    private func confirmAuthorize() async {
        state = .authorizing

        do {
            guard let secretKey = try Keychain.loadString(key: .pubkySecretKey),
                  !secretKey.isEmpty
            else {
                app.toast(type: .error, title: t("pubky_auth__no_identity"))
                state = .authorize
                return
            }

            try await PubkyService.approveAuth(
                authUrl: config.authUrl,
                secretKeyHex: secretKey
            )

            state = .success
        } catch {
            Logger.error("Failed to approve pubky auth: \(error)", context: "PubkyAuthApprovalSheet")
            app.toast(type: .error, title: t("pubky_auth__approval_failed"), description: error.localizedDescription)
            state = .authorize
        }
    }
}
