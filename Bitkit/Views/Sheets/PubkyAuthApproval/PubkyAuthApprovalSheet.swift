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
    let request: PubkyAuthRequest
}

struct PubkyAuthApprovalSheetItem: SheetItem {
    let id: SheetID = .pubkyAuthApproval
    let size: SheetSize = .large
    let request: PubkyAuthRequest
}

// MARK: - Sheet View

struct PubkyAuthApprovalSheet: View {
    @Environment(UsdtWalletManager.self) private var usdt
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var pubkyProfile: PubkyProfileManager
    @EnvironmentObject private var settings: SettingsViewModel

    let config: PubkyAuthApprovalSheetItem

    @State private var state: ApprovalState
    @State private var isShowingAuthCheck = false
    @State private var usdtAddress: String?
    @State private var usdtUnavailable = false
    @State private var showsUsdtAddress = false
    @State private var shareUsdt = true

    private var createsIdentity: Bool {
        Self.requiresIdentityCreation(for: config.request, profile: pubkyProfile)
    }

    enum ApprovalState: Equatable {
        case watchOnlyConsent
        case authorize
        case authorizing
        case success

        var canDismiss: Bool {
            self != .authorizing
        }

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
        request.bitkitClaim?.sharesReceivingDetails == true ? .watchOnlyConsent : .authorize
    }

    static func requiresIdentityCreation(for request: PubkyAuthRequest, profile: PubkyProfileManager) -> Bool {
        request.requiresIdentityCreation(hasIdentity: profile.hasExistingIdentity)
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
        state == .authorize || state == .success
    }

    var body: some View {
        Sheet(id: .pubkyAuthApproval, data: config) {
            if state == .watchOnlyConsent {
                watchOnlyConsentContent
            } else {
                authorizationFlowContent
            }
        }
        .task { await loadUsdtAddress() }
        .interactiveDismissDisabled(!state.canDismiss)
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
            title: t(introTitleKey),
            description: watchOnlyConsentDescription,
            image: "coin-stack",
            continueText: t("pubky_auth__watch_only_intro_approve"),
            cancelText: t("common__cancel"),
            accentColor: config.request.bitkitClaim == .usdtAddressV1 ? .usdtAccent : .blueAccent,
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
                .disabled(config.request.bitkitClaim?.sharesUsdt == true && shareUsdt && usdtAddress == nil)
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
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
            if config.request.bitkitClaim?.sharesBitcoin == true || (shareUsdt && usdtAddress != nil) {
                BodyMText(t(sharingSuccessKey))
                    .accessibilityIdentifier("PubkyAuthSharedDetails")
            }

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
                    if createsIdentity {
                        BodyMText(t("pubky_auth__signup_description"))
                            .padding(.bottom, 16)
                    }

                    if !config.request.permissions.isEmpty {
                        descriptionText
                            .padding(.bottom, 32)
                    }

                    if let relayOrigin = config.request.relayOrigin {
                        relayOriginSection(relayOrigin)
                            .padding(.bottom, 24)
                    }

                    if config.request.bitkitClaim?.sharesReceivingDetails == true {
                        paymentDetailsSection
                            .padding(.bottom, 24)
                    }
                    if !config.request.permissions.isEmpty {
                        permissionsSection
                    }

                    if config.request.bitkitClaim?.includesPaykitAccess == true {
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("pubky_auth__paykit_access_title"), textColor: .white64)
                            BodySText(t("pubky_auth__paykit_access_description"), textColor: .textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 32)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("PubkyAuthPaykitAccess")
                    }

                    Spacer().frame(height: 32)

                    trustWarning
                        .padding(.bottom, 16)

                    if createsIdentity, let homeserver = config.request.homeserverPublicKey {
                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("pubky_auth__homeserver"), textColor: .white64)
                            BodyMSBText(homeserver)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                        .background(Color.gray6)
                        .cornerRadius(16)
                        .padding(.bottom, 16)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("PubkySignupHomeserver")
                    } else {
                        profileCard
                            .padding(.bottom, 16)
                    }
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var serviceText: String {
        config.request.serviceNames.joined(separator: t("profile__auth_approval_services_separator"))
    }

    private var descriptionPrefix: String {
        config.request.clientID.isEmpty ? t("pubky_auth__description_prefix")
            : t("pubky_auth__named_description_prefix", variables: ["clientId": config.request.clientID])
    }

    private var descriptionText: some View {
        BodyMText(
            descriptionPrefix + "<accent>" + serviceText + "</accent>" + t("pubky_auth__description_suffix"),
            accentColor: .textPrimary,
            accentFont: Fonts.bold
        )
        .lineSpacing(4)
    }

    private var introTitleKey: String {
        guard config.request.bitkitClaim?.sharesUsdt == true else { return "pubky_auth__watch_only_intro_title" }
        return config.request.bitkitClaim?.sharesBitcoin == true ? "pubky_auth__payment_details_intro_title" : "pubky_auth__usdt_intro_title"
    }

    private var introDescriptionKey: String {
        guard config.request.bitkitClaim?.sharesUsdt == true else { return "pubky_auth__watch_only_intro_description" }
        return config.request.bitkitClaim?.sharesBitcoin == true ? "pubky_auth__payment_details_intro_description" : "pubky_auth__usdt_intro_description"
    }

    private var sharingSuccessKey: String {
        if shareUsdt, usdtAddress != nil, config.request.bitkitClaim?.sharesUsdt == true {
            return config.request.bitkitClaim?.sharesBitcoin == true ? "pubky_auth__shared_both" : "pubky_auth__shared_usdt"
        }
        return "pubky_auth__shared_bitcoin"
    }

    private var paymentDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            CaptionMText(t("pubky_auth__payment_details"), textColor: .white64)
            if config.request.bitkitClaim?.sharesBitcoin == true {
                VStack(alignment: .leading, spacing: 4) {
                    BodySSBText("Bitcoin", textColor: .brandAccent)
                    BodySText(t("pubky_auth__bitcoin_account"), textColor: .white64)
                }
                .accessibilityIdentifier("PubkyAuthBitcoinDetails")
            }
            if config.request.bitkitClaim?.sharesUsdt == true {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $shareUsdt) {
                        BodySSBText(t("pubky_auth__share_usdt_optional"), textColor: .usdtAccent)
                    }
                    .tint(.usdtAccent)
                    .disabled(state == .authorizing)
                    .accessibilityIdentifier("PubkyAuthShareUsdt")
                    if let usdtAddress {
                        Button { showsUsdtAddress.toggle() } label: {
                            BodySText(showsUsdtAddress ? usdtAddress : String(usdtAddress.prefix(8)) + "…" + String(usdtAddress.suffix(6)))
                                .multilineTextAlignment(.leading)
                        }
                        .accessibilityIdentifier("PubkyAuthUsdtAddress")
                        if showsUsdtAddress {
                            Button(t("common__copy")) { UIPasteboard.general.string = usdtAddress }
                                .tint(.usdtAccent)
                                .accessibilityIdentifier("PubkyAuthCopyUsdtAddress")
                        }
                    } else if usdtUnavailable {
                        BodySText(t("pubky_auth__usdt_unavailable"), textColor: .white64)
                        Button(t("common__retry")) { Task { await loadUsdtAddress() } }
                            .tint(.usdtAccent)
                    } else {
                        ProgressView()
                    }
                    BodySText(t("pubky_auth__usdt_privacy"), textColor: .white64)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("PubkyAuthUsdtDetails")
            }
            CustomDivider(color: .white10)
        }
    }

    private func loadUsdtAddress() async {
        guard config.request.bitkitClaim?.sharesUsdt == true else { return }
        usdtAddress = nil
        usdtUnavailable = false
        do {
            usdtAddress = try await usdt.paymentEndpoint().value
        } catch {
            usdtAddress = nil
            usdtUnavailable = true
            shareUsdt = false
        }
    }

    private var watchOnlyConsentDescription: String {
        let description = t(introDescriptionKey)
        guard let relayOrigin = config.request.relayOrigin else { return description }

        return description + "\n\n" + t(
            "pubky_auth__watch_only_intro_relay",
            variables: ["relay": relayOrigin]
        )
    }

    private func relayOriginSection(_ relayOrigin: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("pubky_auth__authorization_relay"), textColor: .white64)
            BodySSBText(relayOrigin)
                .accessibilityIdentifier("PubkyAuthRelayOrigin")
            CustomDivider(color: .white10)
        }
    }

    private var successDescriptionText: some View {
        BodyMText(
            t("pubky_auth__success_prefix") + "<accent>" + truncatedPublicKey + "</accent>"
                + (config.request.clientID.isEmpty ? t("pubky_auth__success_middle")
                    : t(
                        "pubky_auth__named_success_middle",
                        variables: ["clientId": config.request.clientID]
                    )) + "<accent>" + serviceText + "</accent>"
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
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("pubky_auth__before_continue"), textColor: .white64)
            BodySText(t("pubky_auth__trust_warning"), textColor: .white64)
        }
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            PubkyContactAvatar(name: pubkyProfile.displayName ?? "", imageUrl: pubkyProfile.displayImageUri, size: 48)
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(truncatedPublicKey.localizedUppercase, textColor: .white64)
                    .lineLimit(1)
                BodyMSBText(pubkyProfile.displayName ?? "")
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(Color.gray6)
        .cornerRadius(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PubkyAuthProfile")
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
            if createsIdentity {
                try await pubkyProfile.approveSignupAuth(request: config.request)
                guard sheets.pubkyAuthApprovalSheetItem?.request.rawUrl == config.request.rawUrl else {
                    return
                }
                sheets.hideSheet()
                return
            }

            guard let secretKey = PubkyProfileManager.activeSecretKeyHex() else {
                app.toast(type: .error, title: t("pubky_auth__no_identity"))
                state = .authorize
                return
            }

            try await PubkyService.approveAuthRequest(
                request: config.request,
                authUrl: config.request.rawUrl,
                accountName: watchOnlyAccountName,
                secretKeyHex: secretKey,
                approvedUsdtAddress: shareUsdt ? usdtAddress : nil,
                usdtEndpoint: { try await usdt.paymentEndpoint() }
            )

            state = .success
        } catch {
            if case PubkySignupError.inProgress = error {
                app.toast(type: .info, title: t("pubky_auth__authorizing"))
                state = .authorize
                return
            }
            if case PubkySignupError.alreadySignedIn = error {
                app.toast(type: .info, title: t("pubky_auth__already_signed_in"))
                sheets.hideSheet()
                return
            }
            if config.request.isSignup {
                Logger.error("Failed to approve pubky signup", context: "PubkyAuthApprovalSheet")
            } else {
                Logger.error("Failed to approve pubky auth: \(error)", context: "PubkyAuthApprovalSheet")
            }
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
        guard state.canDismiss else { return }
        if state == .authorize, config.request.bitkitClaim?.sharesReceivingDetails == true {
            state = .watchOnlyConsent
        } else {
            sheets.hideSheet()
        }
    }
}
