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

func pubkyAuthDisplayPublicKey(_ publicKey: String?) -> String {
    guard let publicKey else { return "" }
    let rawKey = publicKey.hasPrefix("pubky") ? String(publicKey.dropFirst("pubky".count)) : publicKey
    guard rawKey.count > 8 else { return rawKey }
    return "\(rawKey.prefix(4))...\(rawKey.suffix(4))"
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

    @State private var state: ApprovalState
    @State private var isShowingAuthCheck = false

    enum ApprovalState: Equatable {
        case watchOnlyConsent
        case authorize
        case authorizing
        case success

        @MainActor
        mutating func approveWatchOnlyConsent() -> Bool {
            guard self == .watchOnlyConsent else { return false }
            self = .authorize
            return true
        }

        @MainActor
        mutating func beginAuthorization() -> Bool {
            guard self == .authorize else { return false }
            self = .authorizing
            return true
        }
    }

    init(config: PubkyAuthApprovalSheetItem) {
        self.config = config
        _state = State(initialValue: Self.initialState(for: config.request))
    }

    static func initialState(for request: PubkyAuthRequest) -> ApprovalState {
        request.bitkitClaim == .watchOnlyAccountV1 ? .watchOnlyConsent : .authorize
    }

    private var headerTitle: String {
        switch state {
        case .watchOnlyConsent:
            t("pubky_auth__watch_only_intro_nav_title")
        case .authorize, .authorizing:
            t("pubky_auth__title")
        case .success:
            t("pubky_auth__success_title")
        }
    }

    private var showsBackButton: Bool {
        state == .authorize || state == .authorizing || state == .success
    }

    var body: some View {
        Sheet(id: .pubkyAuthApproval, data: config) {
            if state == .watchOnlyConsent {
                watchOnlyConsentContent
            } else {
                authorizationFlowContent
            }
        }
        .fullScreenCover(isPresented: $isShowingAuthCheck) {
            AuthCheck(
                onCancel: {
                    isShowingAuthCheck = false
                    state = .authorize
                },
                onPinVerified: {
                    isShowingAuthCheck = false
                    Task {
                        await performAuthorization()
                    }
                }
            )
        }
    }

    // MARK: - Watch-Only Consent

    private var watchOnlyConsentContent: some View {
        SheetIntro(
            navTitle: t("pubky_auth__watch_only_intro_nav_title"),
            title: t("pubky_auth__watch_only_intro_title"),
            description: t("pubky_auth__watch_only_intro_description"),
            image: "coin-stack",
            continueText: t("pubky_auth__watch_only_intro_approve"),
            cancelText: t("common__cancel"),
            accentColor: .blueAccent,
            testID: "PubkyAuthWatchOnlyConsent",
            cancelTestID: "PubkyAuthWatchOnlyCancel",
            continueTestID: "PubkyAuthWatchOnlyApprove",
            onCancel: { sheets.hideSheet() },
            onContinue: { _ = state.approveWatchOnlyConsent() }
        )
    }

    // MARK: - Authorization

    private var authorizationFlowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                title: headerTitle,
                showBackButton: showsBackButton,
                onBack: onBack
            )

            switch state {
            case .watchOnlyConsent:
                EmptyView()
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

    private var authorizeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            approvalDetails

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

    // MARK: - Authorization Progress

    private var authorizingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            approvalDetails

            BodyMSBText(t("pubky_auth__authorizing"), textColor: .white32)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
        }
    }

    // MARK: - Success

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

    private var approvalDetails: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    descriptionText
                        .padding(.bottom, 32)

                    permissionsSection

                    Spacer(minLength: 32)

                    trustWarning
                        .padding(.bottom, 16)

                    profileCard
                        .padding(.bottom, 16)
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
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

    private var successDescriptionText: some View {
        BodyMText(
            t("pubky_auth__success_prefix") + "<accent>" + truncatedPublicKey + "</accent>"
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

            BodySSBText(permission.displayPath)
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
        VStack(spacing: 16) {
            CaptionMText(
                truncatedPublicKey.localizedUppercase,
                textColor: .white64
            )

            if let imageUri = pubkyProfile.displayImageUri {
                PubkyImage(uri: imageUri, size: 96)
            } else {
                Circle()
                    .fill(Color.pubkyGreen)
                    .frame(width: 96, height: 96)
                    .overlay {
                        Image("user-square")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white32)
                            .frame(width: 48, height: 48)
                    }
            }

            HeadlineText(pubkyProfile.displayName ?? "")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.gray6)
        .cornerRadius(16)
    }

    // MARK: - Actions

    @MainActor
    private func onAuthorize() async {
        guard state.beginAuthorization() else { return }

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
            await performAuthorization()
        }
    }

    @MainActor
    private func authorizeWithBiometrics() async {
        let biometricResult = await BiometricAuth.authenticate()

        switch biometricResult {
        case .success:
            await performAuthorization()
        case .cancelled:
            state = .authorize
        case let .failed(message):
            app.toast(type: .error, title: t("pubky_auth__biometric_failed"), description: message)
            state = .authorize
        }
    }

    @MainActor
    private func performAuthorization() async {
        guard state == .authorizing else { return }
        do {
            guard let secretKey = try Keychain.loadString(key: .pubkySecretKey),
                  !secretKey.isEmpty
            else {
                app.toast(type: .error, title: t("pubky_auth__no_identity"))
                state = .authorize
                return
            }

            try await PubkyService.approveAuthRequest(
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

    private var watchOnlyAccountName: String {
        return config.request.serviceNames.first.map {
            t("pubky_auth__watch_only_account_default_name", variables: ["service": $0])
        } ?? t("pubky_auth__watch_only_account_fallback_name")
    }

    private var truncatedPublicKey: String {
        pubkyAuthDisplayPublicKey(pubkyProfile.publicKey ?? pubkyProfile.profile?.publicKey)
    }

    private func onBack() {
        if state == .authorize, config.request.bitkitClaim == .watchOnlyAccountV1 {
            state = .watchOnlyConsent
        } else {
            sheets.hideSheet()
        }
    }
}
