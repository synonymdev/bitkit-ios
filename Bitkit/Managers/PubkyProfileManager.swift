import Foundation
import Paykit
import SwiftUI

enum PubkyAuthState: Equatable {
    case idle
    case authenticating
    case completingAuthentication
    case authenticated
    case error(String)

    func resetRingAuthViewStateIfNeeded(
        isAuthenticating: Binding<Bool>,
        isWaitingForRing: Binding<Bool>,
        isLoadingAfterAuth: Binding<Bool>
    ) {
        switch self {
        case .idle, .authenticated, .error:
            isAuthenticating.wrappedValue = false
            isWaitingForRing.wrappedValue = false
            isLoadingAfterAuth.wrappedValue = false
        case .authenticating, .completingAuthentication:
            break
        }
    }
}

enum PubkyRingAuthCallback: Equatable {
    case success(nonce: String?)
    case cancel(nonce: String?)
    case error(message: String?, nonce: String?)

    var nonce: String? {
        switch self {
        case let .success(nonce), let .cancel(nonce):
            return nonce
        case let .error(_, nonce):
            return nonce
        }
    }

    static func parse(url: URL) -> PubkyRingAuthCallback? {
        guard url.scheme == "bitkit", url.host == "pubky-auth" else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let nonce = components?.queryItems?.first(where: { $0.name == "nonce" })?.value

        switch url.path {
        case "/success":
            return .success(nonce: nonce)
        case "/cancel":
            return .cancel(nonce: nonce)
        case "/error":
            let message = components?.queryItems?.first(where: { $0.name == "errorMessage" })?.value
            return .error(message: message, nonce: nonce)
        default:
            return nil
        }
    }
}

enum PubkyRingAuthCallbackHandlingResult: Equatable {
    case ignored
    case handled
    case trustedError(message: String?)
    case untrustedError
}

enum PubkyRingAuthURLBuilder {
    static let successCallback = "bitkit://pubky-auth/success"
    static let cancelCallback = "bitkit://pubky-auth/cancel"
    static let errorCallback = "bitkit://pubky-auth/error"
    static let source = "Bitkit"

    static func addingCallbacks(to authUrl: String, nonce: UUID? = nil) -> String? {
        guard var components = URLComponents(string: authUrl), components.url != nil else {
            return nil
        }

        let callbackQuery = [
            ("x-success", callbackUrl(successCallback, nonce: nonce)),
            ("x-cancel", callbackUrl(cancelCallback, nonce: nonce)),
            ("x-error", callbackUrl(errorCallback, nonce: nonce)),
            ("x-source", source),
        ]
        .map { "\($0.0)=\(Self.percentEncodedQueryValue($0.1))" }
        .joined(separator: "&")

        components.percentEncodedQuery = [components.percentEncodedQuery, callbackQuery]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "&")

        return components.url?.absoluteString
    }

    private static func callbackUrl(_ baseUrl: String, nonce: UUID?) -> String {
        guard let nonce else {
            return baseUrl
        }

        return "\(baseUrl)?nonce=\(percentEncodedQueryValue(nonce.uuidString))"
    }

    private static func percentEncodedQueryValue(_ value: String) -> String {
        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }
}

private enum PubkyProfileManagerError: LocalizedError {
    case avatarEncodingFailed

    var errorDescription: String? {
        switch self {
        case .avatarEncodingFailed:
            return "Failed to encode avatar image"
        }
    }
}

@MainActor
class PubkyProfileManager: ObservableObject {
    enum SessionInitializationResult: Equatable {
        case noSession
        case restored(publicKey: String)
        case restorationFailed
    }

    @Published var authState: PubkyAuthState = .idle
    @Published var profile: PubkyProfile?
    @Published var publicKey: String?
    @Published var isLoadingProfile = false
    @Published var isInitialized = false
    @Published var initializationErrorMessage: String?
    @Published var sessionRestorationFailed = false
    @Published private(set) var cachedName: String?
    @Published private(set) var cachedImageUri: String?

    private var activeAuthAttemptID: UUID?

    init() {
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
    }

    // MARK: - Initialization & Session Restoration

    /// Initializes Paykit and restores any persisted session.
    func initialize() async {
        isInitialized = false
        initializationErrorMessage = nil
        sessionRestorationFailed = false

        let result: SessionInitializationResult
        do {
            result = try await Task.detached {
                try await Self.initializePersistedSession()
            }.value
        } catch {
            Logger.error("Failed to initialize paykit: \(error)", context: "PubkyProfileManager")
            authState = .idle
            initializationErrorMessage = error.localizedDescription
            return
        }

        switch result {
        case .noSession:
            clearAuthenticatedState()
            Logger.debug("No saved paykit session found", context: "PubkyProfileManager")
        case let .restored(pk):
            publicKey = pk
            authState = .authenticated
            Logger.info("Paykit session restored for \(pk)", context: "PubkyProfileManager")
            Task { await loadProfile() }
        case .restorationFailed:
            clearAuthenticatedState()
            sessionRestorationFailed = true
        }

        isInitialized = true
    }

    // MARK: - Key Derivation & Identity Creation

    /// Derive the Pubky keypair from the wallet's BIP39 seed.
    /// Returns (publicKeyZ32, secretKeyHex).
    func deriveKeys() async throws -> (String, String) {
        return try await Task.detached {
            let secretKeyHex = try Self.deriveLocalSecretKeyFromWalletSeed()
            let rawKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
            let publicKeyZ32 = rawKey.hasPrefix("pubky") ? rawKey : "pubky\(rawKey)"
            return (publicKeyZ32, secretKeyHex)
        }.value
    }

    /// Fetch a signup code and homeserver public key from Homegate's IP verification endpoint.
    struct HomegateResponse: Decodable {
        let signupCode: String
        let homeserverPubky: String
    }

    private static func fetchHomegateSignupCode() async throws -> HomegateResponse {
        let url = URL(string: "\(Env.homegateUrl)/ip_verification")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PubkyServiceError.authFailed("Homegate returned status \(statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(HomegateResponse.self, from: data)
    }

    /// Upload an avatar image to the user's homeserver blob storage. Returns the `pubky://` URI.
    func uploadAvatar(image: UIImage) async throws -> String {
        _ = try activeSessionSecret()
        let imageData = try compressAvatar(image)
        return try await PubkyService.uploadProfileAvatar(bytes: imageData, contentType: "image/jpeg")
    }

    private func compressAvatar(_ image: UIImage, maxSize: CGFloat = 400) throws -> Data {
        // Resize to max dimensions
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
            throw PubkyProfileManagerError.avatarEncodingFailed
        }
        return jpegData
    }

    nonisolated static func resolvedImageUrl(newImageUrl: String?, existingImageUrl: String?) -> String? {
        newImageUrl ?? existingImageUrl
    }

    func createIdentity(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String] = [],
        existingImageUrl: String? = nil,
        avatarImage: UIImage? = nil
    ) async throws {
        let (publicKeyZ32, secretKeyHex) = try await deriveKeys()

        _ = try await Task.detached {
            let homegate = try await Self.fetchHomegateSignupCode()

            var session: String
            do {
                session = try await PubkyService.signUp(
                    secretKeyHex: secretKeyHex,
                    homeserverZ32: homegate.homeserverPubky,
                    signupCode: homegate.signupCode
                )
            } catch {
                Logger.info("signUp failed (likely already registered), trying signIn: \(error)", context: "PubkyProfileManager")
                session = try await PubkyService.signIn(secretKeyHex: secretKeyHex)
            }

            return session
        }.value

        do {
            var avatarUri: String?
            if let avatarImage {
                avatarUri = try await uploadAvatar(image: avatarImage)
            }
            let resolvedImageUrl = Self.resolvedImageUrl(newImageUrl: avatarUri, existingImageUrl: existingImageUrl)

            try await writeProfile(
                name: name,
                bio: bio,
                imageUrl: resolvedImageUrl,
                links: links,
                tags: tags
            )
            Self.notifyAppStateBackupChanged()

            let createdProfile = PubkyProfile(
                publicKey: publicKeyZ32,
                name: name,
                bio: bio,
                imageUrl: resolvedImageUrl,
                links: links,
                tags: tags,
                status: nil
            )

            publicKey = publicKeyZ32
            authState = .authenticated
            profile = createdProfile
            cacheProfileMetadata(createdProfile)
        } catch {
            try? Keychain.delete(key: .pubkySecretKey)
            try? Keychain.delete(key: .paykitSession)
            await PubkyService.forceSignOut()
            throw error
        }

        Logger.info("Pubky identity created for \(publicKeyZ32)", context: "PubkyProfileManager")
    }

    func saveProfile(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String] = [],
        newImageUrl: String? = nil
    ) async throws {
        _ = try activeSessionSecret()

        let resolvedImageUrl = Self.resolvedImageUrl(newImageUrl: newImageUrl, existingImageUrl: profile?.imageUrl)

        try await writeProfile(
            name: name,
            bio: bio,
            imageUrl: resolvedImageUrl,
            links: links,
            tags: tags
        )

        let pk = publicKey ?? ""
        let updatedProfile = PubkyProfile(
            publicKey: pk,
            name: name,
            bio: bio,
            imageUrl: resolvedImageUrl,
            links: links,
            tags: tags,
            status: profile?.status
        )
        profile = updatedProfile
        cacheProfileMetadata(updatedProfile)
    }

    func deleteProfile() async throws {
        do {
            try await Task.detached {
                try await PubkyService.deletePaykitProfile()
            }.value
        } catch {
            guard Self.isMissingBitkitProfileStorageError(error) else {
                throw error
            }

            Logger.info("Bitkit profile storage already missing, continuing sign out", context: "PubkyProfileManager")
        }

        try await signOut()
    }

    private func writeProfile(
        name: String,
        bio: String,
        imageUrl: String?,
        links: [PubkyProfileLink],
        tags: [String] = []
    ) async throws {
        let profileData = PubkyProfileData(
            name: name,
            bio: bio,
            image: imageUrl,
            links: links.map { PubkyProfileData.Link(label: $0.label, url: $0.url) },
            tags: tags
        )

        try await Task.detached {
            try await PubkyService.publishPaykitProfile(profileData.toPaykitProfile())
        }.value
    }

    static func isRingAvailable() -> Bool {
        guard let url = URL(string: "pubkyauth://check") else {
            return false
        }

        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: - Auth Flow (Ring)

    func cancelAuthentication() async {
        activeAuthAttemptID = nil

        do {
            try await Task.detached {
                try await PubkyService.cancelAuth()
            }.value
            restoreAuthStateAfterAuthFlow()
        } catch {
            restoreAuthStateAfterAuthFlow()
            Logger.warn("Cancel auth failed: \(error)", context: "PubkyProfileManager")
        }
    }

    func handleAuthCallback(_ callback: PubkyRingAuthCallback) async -> PubkyRingAuthCallbackHandlingResult {
        guard isCurrentAuthCallback(callback) else {
            return await handleInvalidAuthCallback(callback)
        }

        switch callback {
        case .success:
            Logger.info("Pubky Ring returned auth success callback", context: "PubkyProfileManager")
        case .cancel:
            Logger.info("Pubky Ring returned auth cancel callback", context: "PubkyProfileManager")
            await cancelAuthentication()
        case let .error(message, _):
            Logger.warn("Pubky Ring returned auth error callback: \(message ?? "Unknown error")", context: "PubkyProfileManager")
            await cancelAuthentication()
            setAuthFlowError(message ?? t("profile__auth_error_title"))
            return .trustedError(message: message)
        }

        return .handled
    }

    private func handleInvalidAuthCallback(_ callback: PubkyRingAuthCallback) async -> PubkyRingAuthCallbackHandlingResult {
        switch callback {
        case .success:
            Logger.warn("Ignoring Pubky Ring auth success callback with missing or invalid nonce", context: "PubkyProfileManager")
        case .cancel:
            Logger.warn("Ignoring Pubky Ring auth cancel callback with missing or invalid nonce", context: "PubkyProfileManager")
        case let .error(message, _):
            Logger.warn(
                "Ignoring Pubky Ring auth error callback with missing or invalid nonce: \(message ?? "Unknown error")",
                context: "PubkyProfileManager"
            )
        }

        return .ignored
    }

    func startAuthentication() async throws {
        let attemptID = UUID()
        activeAuthAttemptID = attemptID
        authState = .authenticating

        guard Self.isRingAvailable() else {
            activeAuthAttemptID = nil
            restoreAuthStateAfterAuthFlow()
            throw PubkyServiceError.ringNotInstalled
        }

        let authUrl: String
        do {
            authUrl = try await Task.detached {
                try await PubkyService.startAuth()
            }.value
        } catch {
            activeAuthAttemptID = nil
            restoreAuthStateAfterAuthFlow()
            throw error
        }

        guard activeAuthAttemptID == attemptID else {
            throw CancellationError()
        }

        let callbackAuthUrl = PubkyRingAuthURLBuilder.addingCallbacks(to: authUrl, nonce: attemptID) ?? authUrl

        guard let url = URL(string: callbackAuthUrl) else {
            await cancelPendingAuthSetup()
            activeAuthAttemptID = nil
            restoreAuthStateAfterAuthFlow()
            throw PubkyServiceError.invalidAuthUrl
        }

        let canOpen = UIApplication.shared.canOpenURL(url)
        guard canOpen else {
            await cancelPendingAuthSetup()
            activeAuthAttemptID = nil
            restoreAuthStateAfterAuthFlow()
            throw PubkyServiceError.ringNotInstalled
        }

        let didOpen = await UIApplication.shared.open(url)
        guard didOpen else {
            await cancelPendingAuthSetup()
            activeAuthAttemptID = nil
            restoreAuthStateAfterAuthFlow()
            throw PubkyServiceError.authFailed("Failed to open Pubky Ring")
        }
    }

    /// Long-polls the relay, activates the SDK session, then loads the profile.
    @discardableResult
    func completeAuthentication() async throws -> String {
        guard let attemptID = activeAuthAttemptID else {
            throw CancellationError()
        }

        do {
            _ = try await PubkyService.completeAuth()
            try Task.checkCancellation()
            guard activeAuthAttemptID == attemptID else {
                throw CancellationError()
            }

            guard let pk = await PubkyService.currentPublicKey() else {
                throw PubkyServiceError.sessionNotActive
            }
            try Task.checkCancellation()
            guard activeAuthAttemptID == attemptID else {
                throw CancellationError()
            }

            UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
            Self.notifyAppStateBackupChanged()

            activeAuthAttemptID = nil
            publicKey = pk
            authState = .completingAuthentication
            Logger.info("Pubky auth completed for \(pk)", context: "PubkyProfileManager")
            await loadProfile()
            return pk
        } catch is CancellationError {
            if activeAuthAttemptID == attemptID {
                activeAuthAttemptID = nil
                restoreAuthStateAfterAuthFlow()
            }
            throw CancellationError()
        } catch let serviceError as PubkyServiceError {
            guard activeAuthAttemptID == attemptID else {
                throw CancellationError()
            }

            activeAuthAttemptID = nil
            restoreAuthStateAfterAuthFlow()
            throw serviceError
        } catch {
            guard activeAuthAttemptID == attemptID else {
                throw CancellationError()
            }

            activeAuthAttemptID = nil
            setAuthFlowError(error.localizedDescription)
            throw error
        }
    }

    func finalizeAuthentication() {
        guard case .completingAuthentication = authState else { return }
        authState = .authenticated
    }

    private func restoreAuthStateAfterAuthFlow() {
        authState = publicKey == nil ? .idle : .authenticated
    }

    private func setAuthFlowError(_ message: String) {
        authState = publicKey == nil ? .error(message) : .authenticated
    }

    private func isCurrentAuthCallback(_ callback: PubkyRingAuthCallback) -> Bool {
        guard let activeAuthAttemptID else {
            return false
        }

        return callback.nonce == activeAuthAttemptID.uuidString
    }

    #if DEBUG
        func setActiveAuthAttemptIDForTesting(_ attemptID: UUID?) {
            activeAuthAttemptID = attemptID
        }

        var activeAuthAttemptIDForTesting: UUID? {
            activeAuthAttemptID
        }
    #endif

    // MARK: - Profile

    func loadProfile() async {
        guard let pk = publicKey, !isLoadingProfile else { return }

        isLoadingProfile = true

        do {
            let loadedProfile = try await Task.detached {
                try await Self.resolveRemoteProfile(publicKey: pk)
            }.value
            profile = loadedProfile
            cacheProfileMetadata(loadedProfile)
        } catch {
            Logger.error("Failed to load profile: \(error)", context: "PubkyProfileManager")
        }

        isLoadingProfile = false
    }

    /// Fetch a remote profile by public key. Returns nil if no profile exists.
    func fetchRemoteProfile(publicKey: String) async -> PubkyProfile? {
        do {
            return try await Self.resolveRemoteProfile(publicKey: publicKey)
        } catch {
            Logger.debug("No remote profile found for \(publicKey): \(error)", context: "PubkyProfileManager")
            return nil
        }
    }

    nonisolated static func resolveRemoteProfile(publicKey: String) async throws -> PubkyProfile {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        if let resolution = try await PubkyService.resolveContactProfile(publicKey: normalizedKey, allowPubkyProfileFallback: true) {
            return PubkyProfile(resolution: resolution)
        }

        throw PubkyServiceError.profileNotFound
    }

    // MARK: - Sign Out

    static func clearLocalState() async {
        await PrivatePaykitService.shared.closeAndClear()
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments()
        await PubkyService.forceSignOut()
        try? Keychain.delete(key: .paykitSession)
        try? Keychain.delete(key: .pubkySecretKey)
        await PubkyImageCache.shared.clear()
        UserDefaults.standard.removeObject(forKey: cachedNameKey)
        UserDefaults.standard.removeObject(forKey: cachedImageUriKey)
        ContactsManager.restoreContactProfileOverrides(nil)
        clearPublicPaykitSharingState()
        notifyAppStateBackupChanged()
    }

    private static func clearPublicPaykitSharingState() {
        UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        UserDefaults.standard.set(false, forKey: "hasConfirmedPublicPaykitEndpoints")
        PrivatePaykitService.setContactSharingCleanupPending(false)
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11ExpiresAt")
    }

    static func removePublicPaykitEndpoints(context: String) async throws {
        do {
            try await PublicPaykitService.removePublishedEndpoints()
        } catch PubkyServiceError.sessionNotActive {
            Logger.debug("Skipping public Paykit endpoint cleanup because no session is active", context: context)
        } catch {
            Logger.warn("Failed to remove public Paykit endpoints before clearing session: \(error)", context: context)
            throw error
        }
    }

    static func removePublicPaykitEndpointsBestEffort(context: String) async {
        do {
            try await removePublicPaykitEndpoints(context: context)
            PublicPaykitService.setCleanupPending(false)
        } catch {
            PublicPaykitService.setCleanupPending(true)
        }
    }

    static func removePrivatePaykitEndpoints(context: String) async throws {
        do {
            try await PrivatePaykitService.shared.removePublishedEndpoints()
        } catch {
            Logger.warn("Failed to remove private Paykit endpoints before clearing session: \(error)", context: context)
            throw error
        }
    }

    static func removePrivatePaykitEndpointsBestEffort(context: String) async {
        try? await removePrivatePaykitEndpoints(context: context)
    }

    func signOut() async throws {
        try await Task.detached {
            await Self.removePublicPaykitEndpointsBestEffort(context: "PubkyProfileManager.signOut")
            try await Self.removePrivatePaykitEndpoints(context: "PubkyProfileManager.signOut")
            do {
                try await PubkyService.signOut()
            } catch {
                Logger.warn("Server sign out failed, forcing local sign out: \(error)", context: "PubkyProfileManager")
            }
            await Self.clearLocalState()
        }.value

        clearAuthenticatedState()
    }

    func refreshSessionIfPossible(after error: Error) async -> Bool {
        await Self.refreshSessionIfPossible(
            after: error,
            loadKeychainString: { try Keychain.loadString(key: $0) },
            signInWithSecretKey: { try await PubkyService.signIn(secretKeyHex: $0) }
        )
    }

    // MARK: - Cached Profile Metadata

    private static let cachedNameKey = "pubky_profile_name"
    private static let cachedImageUriKey = "pubky_profile_image_uri"

    var displayName: String? {
        profile?.name ?? cachedName
    }

    var displayImageUri: String? {
        profile?.imageUrl ?? cachedImageUri
    }

    private func cacheProfileMetadata(_ profile: PubkyProfile) {
        cachedName = profile.name
        cachedImageUri = profile.imageUrl
        UserDefaults.standard.set(profile.name, forKey: Self.cachedNameKey)
        UserDefaults.standard.set(profile.imageUrl, forKey: Self.cachedImageUriKey)
    }

    private func clearCachedProfileMetadata() {
        cachedName = nil
        cachedImageUri = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedNameKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedImageUriKey)
    }

    private func clearAuthenticatedState() {
        publicKey = nil
        profile = nil
        authState = .idle
        clearCachedProfileMetadata()
    }

    private func activeSessionSecret() throws -> String {
        guard let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else {
            throw PubkyServiceError.sessionNotActive
        }
        return sessionSecret
    }

    // MARK: - Session & Backup Helpers

    var isAuthenticated: Bool {
        publicKey != nil
    }

    var hasLocalSecretKeyForCurrentProfile: Bool {
        Self.hasLocalSecretKey(for: publicKey)
    }

    nonisolated static func hasLocalSecretKey(for publicKey: String?) -> Bool {
        guard let publicKey,
              let secretKeyHex = try? Keychain.loadString(key: .pubkySecretKey),
              !secretKeyHex.isEmpty,
              let rawPublicKey = try? PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        else {
            return false
        }

        let prefixedPublicKey = rawPublicKey.hasPrefix("pubky") ? rawPublicKey : "pubky\(rawPublicKey)"
        return PubkyPublicKeyFormat.matches(prefixedPublicKey, publicKey)
    }

    nonisolated static func snapshotSessionBackupState(
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        }
    ) throws -> PubkySessionBackupV1? {
        if let secretKeyHex = try loadKeychainString(.pubkySecretKey),
           !secretKeyHex.isEmpty
        {
            return PubkySessionBackupV1(kind: .localSeed, sessionSecret: nil)
        }

        if let sessionSecret = try loadKeychainString(.paykitSession),
           !sessionSecret.isEmpty
        {
            return PubkySessionBackupV1(kind: .externalSession, sessionSecret: sessionSecret)
        }

        return nil
    }

    nonisolated static func restoreSessionBackupState(
        _ backup: PubkySessionBackupV1?,
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        },
        deleteKeychainValue: (KeychainEntryType) throws -> Void = {
            try Keychain.delete(key: $0)
        },
        clearSessionAccess: @escaping () async -> Void = {
            await PubkyService.clearSessionAccess()
        },
        signInWithSecretKey: @escaping (String) async throws -> String = {
            try await PubkyService.signIn(secretKeyHex: $0)
        },
        importExternalSession: @escaping (String) async throws -> String = {
            try await PubkyService.importExternalSession(secret: $0)
        }
    ) async throws {
        await clearSessionAccess()

        switch backup?.kind {
        case .none:
            // Missing pubky backup state clears restored pubky credentials, including legacy backups without this field.
            try? deleteKeychainValue(.paykitSession)
            try? deleteKeychainValue(.pubkySecretKey)
        case .localSeed:
            let secretKeyHex = try deriveLocalSecretKeyFromWalletSeed(loadKeychainString: loadKeychainString)
            _ = try await signInWithSecretKey(secretKeyHex)
        case .externalSession:
            guard let sessionSecret = backup?.sessionSecret,
                  !sessionSecret.isEmpty
            else {
                throw PubkyServiceError.authFailed("Missing session secret in backup")
            }
            _ = try await importExternalSession(sessionSecret)
        }
    }

    private func cancelPendingAuthSetup() async {
        do {
            try await Task.detached {
                try await PubkyService.cancelAuth()
            }.value
        } catch {
            Logger.warn("Cancel pending auth setup failed: \(error)", context: "PubkyProfileManager")
        }
    }

    private nonisolated static func initializePersistedSession() async throws -> SessionInitializationResult {
        try await PubkyService.initialize()

        let savedSecret = try Keychain.loadString(key: .paykitSession)
        let secretKeyHex = try Keychain.loadString(key: .pubkySecretKey)
        return await resolveSessionInitialization(
            savedSessionSecret: savedSecret,
            storedSecretKeyHex: secretKeyHex,
            importSession: { try await PubkyService.importSession(secret: $0) },
            signInWithSecretKey: { try await PubkyService.signIn(secretKeyHex: $0) },
            deleteSessionSecret: {
                try? Keychain.delete(key: .paykitSession)
            }
        )
    }

    private nonisolated static func notifyAppStateBackupChanged() {
        Task { @MainActor in
            SettingsViewModel.shared.notifyAppStateChanged()
        }
    }

    private nonisolated static func deriveLocalSecretKeyFromWalletSeed(
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        }
    ) throws -> String {
        guard let mnemonic = try loadKeychainString(.bip39Mnemonic(index: 0)),
              !mnemonic.isEmpty
        else {
            throw PubkyServiceError.authFailed("Mnemonic not found")
        }

        let passphrase = try loadKeychainString(.bip39Passphrase(index: 0))
        let seed = try PubkyService.mnemonicToSeed(mnemonic: mnemonic, passphrase: passphrase)
        return try PubkyService.derivePubkySecretKey(seed: seed)
    }

    nonisolated static func publicKeyFromSecretKey(_ secretKeyHex: String) throws -> String {
        let publicKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        guard let normalized = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PubkyServiceError.authFailed("Invalid Pubky public key")
        }
        return normalized
    }

    nonisolated static func isMissingBitkitProfileStorageError(_ error: Error) -> Bool {
        if case .profileNotFound = error as? PubkyServiceError {
            return true
        }

        let errorText = [
            (error as? AppError)?.debugMessage,
            error.localizedDescription,
            String(describing: error),
        ]
        .compactMap { $0?.lowercased() }

        if errorText.contains(where: { $0.contains("404 not found") || $0.contains("directory not found") }) {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            let cocoaCode = CocoaError.Code(rawValue: nsError.code)
            return cocoaCode == .fileNoSuchFile || cocoaCode == .fileReadNoSuchFile
        }

        return false
    }

    nonisolated static func isSessionRefreshableError(_ error: Error) -> Bool {
        let errorText = [
            (error as? AppError)?.debugMessage,
            error.localizedDescription,
            String(describing: error),
        ]
        .compactMap { $0?.lowercased() }

        return errorText.contains {
            ($0.contains("authfailed") || $0.contains("authentication failed") || $0.contains("sessionnotactive"))
                || ($0.contains("transport error") && $0.contains("/session"))
        }
    }

    nonisolated static func refreshSessionIfPossible(
        after error: Error,
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        },
        signInWithSecretKey: (String) async throws -> String,
        publicKeyFromSecretKey: (String) throws -> String = {
            try PubkyProfileManager.publicKeyFromSecretKey($0)
        }
    ) async -> Bool {
        guard isSessionRefreshableError(error) else {
            return false
        }

        guard let secretKeyHex = try? loadKeychainString(.pubkySecretKey),
              !secretKeyHex.isEmpty
        else {
            Logger.warn("Cannot refresh pubky session without a local secret key", context: "PubkyProfileManager")
            return false
        }

        do {
            _ = try await signInWithSecretKey(secretKeyHex)
            _ = try publicKeyFromSecretKey(secretKeyHex)
            Logger.info("Refreshed pubky session from local secret key", context: "PubkyProfileManager")
            return true
        } catch {
            Logger.warn("Failed to refresh pubky session: \(error)", context: "PubkyProfileManager")
            return false
        }
    }

    nonisolated static func resolveSessionInitialization(
        savedSessionSecret: String?,
        storedSecretKeyHex: String?,
        importSession: (String) async throws -> String,
        signInWithSecretKey: (String) async throws -> String,
        publicKeyFromSecretKey: (String) throws -> String = {
            try PubkyProfileManager.publicKeyFromSecretKey($0)
        },
        deleteSessionSecret: () -> Void
    ) async -> SessionInitializationResult {
        if let savedSessionSecret,
           !savedSessionSecret.isEmpty
        {
            do {
                let publicKey = try await importSession(savedSessionSecret)
                return .restored(publicKey: publicKey)
            } catch {
                Logger.warn("Failed to import saved session, attempting re-sign-in: \(error)", context: "PubkyProfileManager")
            }
        }

        guard let storedSecretKeyHex,
              !storedSecretKeyHex.isEmpty
        else {
            if let savedSessionSecret,
               !savedSessionSecret.isEmpty
            {
                // External sessions cannot recover without a secret key, so keep the saved session for a later retry.
                Logger.warn("No secret key to recover session", context: "PubkyProfileManager")
                return .restorationFailed
            }

            return .noSession
        }

        do {
            _ = try await signInWithSecretKey(storedSecretKeyHex)
            let publicKey = try publicKeyFromSecretKey(storedSecretKeyHex)
            Logger.info("Re-signed in and restored session for \(publicKey)", context: "PubkyProfileManager")
            return .restored(publicKey: publicKey)
        } catch {
            Logger.error("Re-sign-in failed, clearing session: \(error)", context: "PubkyProfileManager")
            deleteSessionSecret()
            return .restorationFailed
        }
    }
}
