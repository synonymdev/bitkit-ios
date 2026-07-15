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

typealias OrdinaryPubkyAuthApproval = (String, String, String) async throws -> Void
typealias CompanionPubkyAuthApproval = (String, Data, String) async throws -> Void

@MainActor
func approvePubkyAuthRequest(
    request: PubkyAuthRequest,
    authUrl: String,
    accountName: String,
    secretKeyHex: String,
    accountManager: WatchOnlyAccountManager? = nil,
    ordinaryApproval: @escaping OrdinaryPubkyAuthApproval = { authUrl, capabilities, secretKeyHex in
        try await PubkyService.approveAuth(
            authUrl: authUrl,
            expectedCapabilities: capabilities,
            secretKeyHex: secretKeyHex
        )
    },
    companionApproval: @escaping CompanionPubkyAuthApproval = { authUrl, unsignedPayload, secretKeyHex in
        try await PubkyService.approveAuthWithCompanionClaim(
            authUrl: authUrl,
            unsignedPayload: unsignedPayload,
            secretKeyHex: secretKeyHex
        )
    }
) async throws {
    let accountManager = accountManager ?? .shared
    if request.bitkitClaim == .watchOnlyAccountV1 {
        let preparedClaim = try await accountManager.prepareUnsignedClaim(authUrl: authUrl, name: accountName)
        do {
            try await accountManager.beginSetupAuthorization(id: preparedClaim.0.id)
        } catch {
            do {
                try await accountManager.cancelSetupAuthorization(id: preparedClaim.0.id)
            } catch let cleanupError {
                Logger.error("Failed to unload incomplete watch-only account: \(cleanupError)", context: "PubkyAuthApprovalSheet")
            }
            throw error
        }
        do {
            try await companionApproval(authUrl, preparedClaim.1, secretKeyHex)
        } catch {
            if !PubkyService.didDeliverCompanionClaim(error: error) {
                do {
                    try await accountManager.cancelSetupAuthorization(id: preparedClaim.0.id)
                } catch let cleanupError {
                    Logger.error("Failed to unload incomplete watch-only account: \(cleanupError)", context: "PubkyAuthApprovalSheet")
                }
            }
            throw error
        }
        try accountManager.markSetupActive(id: preparedClaim.0.id)
    } else {
        try await ordinaryApproval(authUrl, request.capabilities, secretKeyHex)
    }
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
    @State private var watchOnlyAccountName = ""

    enum ApprovalState {
        case authorize
        case authorizing
        case success

        @MainActor
        mutating func beginAuthorization() -> Bool {
            guard self == .authorize else { return false }
            self = .authorizing
            return true
        }
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
        .task {
            guard config.request.bitkitClaim != nil, watchOnlyAccountName.isEmpty else { return }
            watchOnlyAccountName = config.request.serviceNames.first.map {
                t("pubky_auth__watch_only_account_default_name", variables: ["service": $0])
            } ?? t("pubky_auth__watch_only_account_fallback_name")
        }
    }

    // MARK: - Authorize State (Screen 3)

    private var authorizeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            approvalDetails(disablesName: false)

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
            approvalDetails(disablesName: true)

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

    private func approvalDetails(disablesName: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                descriptionText
                    .padding(.bottom, 32)

                permissionsSection
                    .padding(.bottom, 16)

                if config.request.bitkitClaim != nil {
                    bitkitClaimSection
                        .padding(.bottom, 16)

                    watchOnlyAccountNameSection
                        .disabled(disablesName)
                        .padding(.bottom, 16)
                }

                trustWarning
                    .padding(.bottom, 16)

                profileCard
                    .padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
    }

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

    @ViewBuilder
    private var bitkitClaimSection: some View {
        switch config.request.bitkitClaim {
        case .some(.watchOnlyAccountV1):
            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(t("pubky_auth__watch_only_account_title"), textColor: .white64)
                BodySText(t("pubky_auth__watch_only_account_description"))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(16)
            .accessibilityIdentifier("PubkyAuthWatchOnlyAccountClaim")
        case nil:
            EmptyView()
        }
    }

    private var watchOnlyAccountNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("pubky_auth__watch_only_account_name_label"), textColor: .white64)
            TextField(
                t("pubky_auth__watch_only_account_name_placeholder"),
                text: $watchOnlyAccountName,
                testIdentifier: "PubkyAuthWatchOnlyAccountName"
            )
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
        guard state.beginAuthorization() else { return }

        do {
            guard let secretKey = try Keychain.loadString(key: .pubkySecretKey),
                  !secretKey.isEmpty
            else {
                app.toast(type: .error, title: t("pubky_auth__no_identity"))
                state = .authorize
                return
            }

            try await approvePubkyAuthRequest(
                request: config.request,
                authUrl: config.authUrl,
                accountName: watchOnlyAccountName,
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
