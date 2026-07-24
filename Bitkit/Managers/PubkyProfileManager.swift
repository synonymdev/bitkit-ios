import Foundation
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

private actor PubkyIdentityLifecycleLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
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
    @Published private(set) var sharedRingIdentities: [SharedPubkyIdentityOption] = []
    @Published private(set) var isLoadingSharedRingIdentities = false
    @Published private(set) var isSharedIdentityDiscoveryAvailable = true

    private nonisolated static let identityLifecycleLock = PubkyIdentityLifecycleLock()
    private var activeAuthAttemptID: UUID?

    nonisolated static func withIdentityLifecycleLock<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await identityLifecycleLock.withLock(operation)
    }

    init() {
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
    }

    // MARK: - Initialization & Session Restoration

    /// Initializes Paykit and restores any persisted session.
    func initialize() async {
        await Self.withIdentityLifecycleLock {
            await self.initializeLocked()
        }
    }

    private func initializeLocked() async {
        isInitialized = false
        initializationErrorMessage = nil
        sessionRestorationFailed = false

        let result: SessionInitializationResult
        if sharedIdentitySourceIsUnavailable() {
            do {
                try await Self.clearSharedIdentitySession()
            } catch {
                Logger.error("Failed to clear unavailable shared Pubky session: \(error)", context: "PubkyProfileManager")
            }
            result = .restorationFailed
        } else {
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
        }

        switch result {
        case .noSession:
            clearAuthenticatedState()
            Logger.debug("No saved paykit session found", context: "PubkyProfileManager")
        case let .restored(pk):
            publicKey = pk
            authState = .authenticated
            Logger.info("Paykit session restored for \(pk)", context: "PubkyProfileManager")
            await reconcileBitkitOwnedIdentityIfNeededLocked(publicKey: pk)
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
        try await Self.withIdentityLifecycleLock {
            try await self.createIdentityLocked(
                name: name,
                bio: bio,
                links: links,
                tags: tags,
                existingImageUrl: existingImageUrl,
                avatarImage: avatarImage
            )
        }
    }

    private func createIdentityLocked(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String],
        existingImageUrl: String?,
        avatarImage: UIImage?
    ) async throws {
        try Task.checkCancellation()
        guard publicKey == nil,
              try SharedPubkyIdentityReferenceStore.load() == nil,
              try Keychain.loadString(key: .paykitSession)?.isEmpty != false,
              try Keychain.loadString(key: .pubkySecretKey)?.isEmpty != false
        else {
            throw PubkyServiceError.authFailed("A Pubky identity is already recoverable")
        }
        let (publicKeyZ32, secretKeyHex) = try await deriveKeys()

        try Task.checkCancellation()
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
            try Task.checkCancellation()
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
            try SharedPubkyIdentityReferenceStore.delete()
            await reconcileBitkitOwnedIdentityIfNeededLocked(publicKey: publicKeyZ32)
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
        try await Self.withIdentityLifecycleLock {
            try await self.deleteProfileLocked()
        }
    }

    private func deleteProfileLocked() async throws {
        let deletedPublicKey = publicKey
        let ownsIdentity = hasLocalSecretKeyForCurrentProfile

        // Remove and verify the interoperability mirror before touching the canonical private identity.
        if ownsIdentity, let deletedPublicKey {
            try SharedPubkyIdentityVault.deleteBitkitIdentity(pubky: deletedPublicKey)
        }

        try await Self.removePrivatePaykitEndpoints(context: "PubkyProfileManager.deleteProfile")
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

        try await signOutLocked(cleanPrivatePaykitEndpoints: false)
        if ownsIdentity, let deletedPublicKey {
            try SharedPubkyIdentityVault.deleteBitkitIdentity(pubky: deletedPublicKey)
        }
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
        // This is an availability hint, not an identity proof: URL schemes can be claimed by
        // another app. Shared-Keychain entitlement and payload validation remain the trust
        // boundary. A source-authenticated liveness handshake is a follow-up release hardening.
        guard let url = URL(string: "pubkyauth://check") else {
            return false
        }

        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: - Shared Identity Discovery

    func refreshSharedRingIdentities() async {
        guard publicKey == nil else {
            sharedRingIdentities = []
            return
        }

        guard Self.isRingAvailable() else {
            sharedRingIdentities = []
            isSharedIdentityDiscoveryAvailable = true
            return
        }

        isLoadingSharedRingIdentities = true
        defer { isLoadingSharedRingIdentities = false }

        do {
            let references = try await Task.detached {
                try SharedPubkyIdentityVault.list(source: .ring)
            }.value
            var options: [SharedPubkyIdentityOption] = []
            for reference in references {
                guard let prefixedPubky = SharedPubkyKeyFormat.prefixed(reference.pubky) else {
                    continue
                }
                let profile = await fetchRemoteProfile(publicKey: prefixedPubky)
                    ?? PubkyProfile.placeholder(publicKey: prefixedPubky)
                options.append(SharedPubkyIdentityOption(reference: reference, profile: profile))
            }

            sharedRingIdentities = options.sorted {
                let lhsName = $0.profile.name.localizedLowercase
                let rhsName = $1.profile.name.localizedLowercase
                return lhsName == rhsName
                    ? $0.reference.pubky < $1.reference.pubky
                    : lhsName < rhsName
            }
            isSharedIdentityDiscoveryAvailable = true
        } catch SharedPubkyIdentityError.missingEntitlement {
            sharedRingIdentities = []
            isSharedIdentityDiscoveryAvailable = false
            Logger.info("Shared Pubky Keychain entitlement is not available yet", context: "PubkyProfileManager")
        } catch {
            sharedRingIdentities = []
            isSharedIdentityDiscoveryAvailable = false
            Logger.warn("Failed to discover Pubky Ring identities: \(error)", context: "PubkyProfileManager")
        }
    }

    @discardableResult
    func useSharedRingIdentity(_ option: SharedPubkyIdentityOption) async throws -> String {
        try await Self.withIdentityLifecycleLock {
            try await self.useSharedRingIdentityLocked(option)
        }
    }

    private func useSharedRingIdentityLocked(_ option: SharedPubkyIdentityOption) async throws -> String {
        guard publicKey == nil,
              try SharedPubkyIdentityReferenceStore.load() == nil,
              try Keychain.loadString(key: .paykitSession)?.isEmpty != false,
              try Keychain.loadString(key: .pubkySecretKey)?.isEmpty != false
        else {
            throw PubkyServiceError.authFailed("A Pubky identity is already recoverable")
        }
        guard Self.isRingAvailable() else {
            throw SharedPubkyIdentityError.sourceUnavailable
        }

        authState = .authenticating
        do {
            try Task.checkCancellation()
            let secretKey = try await Task.detached {
                try SharedPubkyIdentityVault.loadCredential(reference: option.reference)
            }.value
            try Task.checkCancellation()
            let prefixedPubky = try await Self.establishSharedIdentitySession(
                reference: option.reference,
                secretKey: secretKey,
                saveReference: { try SharedPubkyIdentityReferenceStore.save($0) },
                signIn: { try await PubkyService.signInSharedIdentity(secretKeyHex: $0) },
                currentPublicKey: { await PubkyService.currentPublicKey() },
                clearSession: { try await PubkyService.clearExternalSessionAccess() },
                deleteReference: { try SharedPubkyIdentityReferenceStore.delete() }
            )

            UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
            Self.notifyAppStateBackupChanged()
            publicKey = prefixedPubky
            profile = option.profile
            cacheProfileMetadata(option.profile)
            authState = .completingAuthentication
            await loadProfile()
            return prefixedPubky
        } catch {
            authState = .idle
            throw error
        }
    }

    nonisolated static func establishSharedIdentitySession(
        reference: SharedPubkyIdentityRefV1,
        secretKey: String,
        saveReference: (SharedPubkyIdentityRefV1) throws -> Void,
        signIn: (String) async throws -> String,
        currentPublicKey: () async -> String?,
        clearSession: () async throws -> Void,
        deleteReference: () throws -> Void
    ) async throws -> String {
        do {
            // The reference is the crash-safety marker. A launch after this write can revalidate
            // the source and sign in again; no borrowed session can exist without it.
            try saveReference(reference)
            _ = try await signIn(secretKey)

            guard let signedInPublicKey = await currentPublicKey(),
                  SharedPubkyKeyFormat.normalizedBare(signedInPublicKey) == reference.pubky,
                  let prefixedPubky = SharedPubkyKeyFormat.prefixed(reference.pubky)
            else {
                throw SharedPubkyIdentityError.secretDoesNotMatchPublicKey
            }
            return prefixedPubky
        } catch let adoptionError {
            do {
                // The durable source reference is also the cleanup-pending marker. Keep it until
                // the local session is verifiably gone so launch/foreground validation retries.
                try await clearSession()
                try deleteReference()
            } catch {
                throw error
            }
            throw adoptionError
        }
    }

    /// Revalidates a borrowed identity without retaining its shared secret.
    func validateSharedIdentitySourceIfNeeded() async {
        await Self.withIdentityLifecycleLock {
            await self.validateSharedIdentitySourceIfNeededLocked()
        }
    }

    private func validateSharedIdentitySourceIfNeededLocked() async {
        let reference: SharedPubkyIdentityRefV1?
        do {
            reference = try SharedPubkyIdentityReferenceStore.load()
        } catch {
            await disconnectUnavailableSharedIdentityLocked()
            return
        }

        guard let reference else {
            if let publicKey {
                await reconcileBitkitOwnedIdentityIfNeededLocked(publicKey: publicKey)
            }
            return
        }

        guard reference.sourceApp == .ring, Self.isRingAvailable() else {
            await disconnectUnavailableSharedIdentityLocked()
            return
        }

        do {
            _ = try await Task.detached {
                try SharedPubkyIdentityVault.loadCredential(reference: reference)
            }.value
        } catch {
            Logger.warn("Shared Pubky source became unavailable: \(error)", context: "PubkyProfileManager")
            await disconnectUnavailableSharedIdentityLocked()
        }
    }

    private func sharedIdentitySourceIsUnavailable() -> Bool {
        do {
            guard let reference = try SharedPubkyIdentityReferenceStore.load() else {
                return false
            }
            return reference.sourceApp != .ring || !Self.isRingAvailable()
        } catch {
            return true
        }
    }

    private func disconnectUnavailableSharedIdentityLocked() async {
        sharedRingIdentities = []
        do {
            try await Self.clearSharedIdentitySession()
            clearAuthenticatedState()
            sessionRestorationFailed = true
        } catch {
            // Keep the durable reference as a cleanup-pending marker and retry on the next
            // launch/foreground validation. Authenticated operations still fail source checks.
            Logger.error("Failed to clear unavailable shared Pubky session: \(error)", context: "PubkyProfileManager")
            sessionRestorationFailed = true
        }
    }

    static func clearSharedIdentitySession(
        clearSession: () async throws -> Void = {
            try await PubkyService.clearExternalSessionAccess()
        },
        deleteReference: () throws -> Void = {
            try SharedPubkyIdentityReferenceStore.delete()
        }
    ) async throws {
        // Session-first ordering prevents an orphaned session from ever outliving its source
        // reference. If either step fails, the remaining reference drives a later retry.
        try await clearSession()
        try deleteReference()
    }

    private func reconcileBitkitOwnedIdentityIfNeededLocked(publicKey: String) async {
        guard (try? SharedPubkyIdentityReferenceStore.load()) == nil,
              let secretKey = try? Keychain.loadString(key: .pubkySecretKey),
              !secretKey.isEmpty,
              Self.hasLocalSecretKey(for: publicKey)
        else {
            return
        }

        do {
            try await Task.detached {
                try SharedPubkyIdentityVault.publishBitkitIdentity(pubky: publicKey, secretKey: secretKey)
            }.value
        } catch SharedPubkyIdentityError.missingEntitlement {
            Logger.info("Deferring shared Pubky mirror until its entitlement is available", context: "PubkyProfileManager")
        } catch {
            Logger.warn("Failed to reconcile Bitkit-owned shared Pubky identity: \(error)", context: "PubkyProfileManager")
        }
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
        try await Self.withIdentityLifecycleLock {
            try await self.completeAuthentication(
                completeAuth: { _ = try await PubkyService.completeAuth() },
                currentPublicKey: { await PubkyService.currentPublicKey() },
                clearSessionAccess: { await PubkyService.clearSessionAccess() }
            )
        }
    }

    @discardableResult
    private func completeAuthentication(
        completeAuth: @escaping () async throws -> Void,
        currentPublicKey: @escaping () async -> String?,
        clearSessionAccess: @escaping () async -> Void
    ) async throws -> String {
        guard let attemptID = activeAuthAttemptID else {
            throw CancellationError()
        }
        var didCompleteAuth = false

        do {
            try await completeAuth()
            didCompleteAuth = true
            try Task.checkCancellation()
            guard activeAuthAttemptID == attemptID else {
                throw CancellationError()
            }

            guard let pk = await currentPublicKey() else {
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
            await clearCompletedAuthSessionIfNeeded(didCompleteAuth, clearSessionAccess: clearSessionAccess)
            if activeAuthAttemptID == attemptID {
                activeAuthAttemptID = nil
                restoreAuthStateAfterAuthFlow()
            }
            throw CancellationError()
        } catch let serviceError as PubkyServiceError {
            await clearCompletedAuthSessionIfNeeded(didCompleteAuth, clearSessionAccess: clearSessionAccess)
            guard activeAuthAttemptID == attemptID else {
                throw CancellationError()
            }

            activeAuthAttemptID = nil
            restoreAuthStateAfterAuthFlow()
            throw serviceError
        } catch {
            await clearCompletedAuthSessionIfNeeded(didCompleteAuth, clearSessionAccess: clearSessionAccess)
            guard activeAuthAttemptID == attemptID else {
                throw CancellationError()
            }

            activeAuthAttemptID = nil
            setAuthFlowError(error.localizedDescription)
            throw error
        }
    }

    private func clearCompletedAuthSessionIfNeeded(_ didCompleteAuth: Bool, clearSessionAccess: @escaping () async -> Void) async {
        guard didCompleteAuth else { return }
        await clearSessionAccess()
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

        @discardableResult
        func completeAuthenticationForTesting(
            completeAuth: @escaping () async throws -> Void,
            currentPublicKey: @escaping () async -> String?,
            clearSessionAccess: @escaping () async -> Void
        ) async throws -> String {
            try await completeAuthentication(
                completeAuth: completeAuth,
                currentPublicKey: currentPublicKey,
                clearSessionAccess: clearSessionAccess
            )
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
        // Callers replacing or deleting a Bitkit-owned private identity must first
        // delete and verify its shared mirror. Ring-owned records are never deleted here.
        await PrivatePaykitService.shared.closeAndClear()
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments()
        await PubkyService.forceSignOut()
        try? Keychain.delete(key: .paykitSession)
        try? Keychain.delete(key: .pubkySecretKey)
        try? SharedPubkyIdentityReferenceStore.delete()
        await PubkyImageCache.shared.clear()
        UserDefaults.standard.removeObject(forKey: cachedNameKey)
        UserDefaults.standard.removeObject(forKey: cachedImageUriKey)
        ContactsManager.restoreContactProfileOverrides(nil)
        clearPublicPaykitSharingState()
        notifyAppStateBackupChanged()
    }

    private nonisolated static func deletePrivateIdentityCredentials() throws {
        try Keychain.delete(key: .paykitSession)
        try Keychain.delete(key: .pubkySecretKey)
        guard try Keychain.load(key: .paykitSession) == nil,
              try Keychain.load(key: .pubkySecretKey) == nil
        else {
            throw KeychainError.failedToDelete
        }
    }

    private static func clearPublicPaykitSharingState() {
        UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        UserDefaults.standard.set(false, forKey: ContactPaymentsService.confirmedPreferenceKey)
        PrivatePaykitService.setContactSharingCleanupPending(false)
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11ExpiresAt")
    }

    static func removePublicPaykitEndpoints(context: String) async throws {
        var firstError: Error?
        do {
            try await PublicPaykitService.removePublishedEndpoints()
        } catch PubkyServiceError.sessionNotActive {
            Logger.debug("Skipping public Paykit endpoint cleanup because no session is active", context: context)
        } catch {
            firstError = error
        }

        do {
            try await PublicPaykitService.syncLocalReceiverMarker(publicSharingEnabled: false, privateSharingEnabled: false)
        } catch PubkyServiceError.sessionNotActive {
            Logger.debug("Skipping Paykit receiver marker cleanup because no session is active", context: context)
        } catch {
            firstError = firstError ?? error
        }

        if let firstError {
            Logger.warn("Failed to remove public Paykit state before clearing session: \(firstError)", context: context)
            throw firstError
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
            PrivatePaykitService.setContactSharingCleanupPending(false)
        } catch {
            PrivatePaykitService.setContactSharingCleanupPending(true)
            Logger.warn("Failed to remove private Paykit endpoints before clearing session: \(error)", context: context)
            throw error
        }
    }

    static func removePrivatePaykitEndpointsBestEffort(context: String) async {
        do {
            try await removePrivatePaykitEndpoints(context: context)
            PrivatePaykitService.setContactSharingCleanupPending(false)
        } catch {
            PrivatePaykitService.setContactSharingCleanupPending(true)
        }
    }

    func signOut() async throws {
        try await Self.withIdentityLifecycleLock {
            try await self.signOutLocked(cleanPrivatePaykitEndpoints: true)
        }
    }

    private func signOutLocked(cleanPrivatePaykitEndpoints: Bool) async throws {
        let sharedReference = try SharedPubkyIdentityReferenceStore.load()
        let localSecret = try Keychain.loadString(key: .pubkySecretKey)
        if sharedReference != nil, localSecret?.isEmpty == false {
            throw SharedPubkyIdentityError.provenanceConflict
        }

        let ownsIdentity = hasLocalSecretKeyForCurrentProfile
        if localSecret?.isEmpty == false, !ownsIdentity {
            throw SharedPubkyIdentityError.provenanceConflict
        }
        let hasSharedReference = sharedReference != nil
        if ownsIdentity, let sourcePublicKey = publicKey {
            try SharedPubkyIdentityVault.deleteBitkitIdentity(pubky: sourcePublicKey)
        }

        try await Task.detached {
            if cleanPrivatePaykitEndpoints {
                try await Self.removePrivatePaykitEndpoints(context: "PubkyProfileManager.signOut")
            }
            await Self.removePublicPaykitEndpointsBestEffort(context: "PubkyProfileManager.signOut")
            do {
                try await PubkyService.signOut()
            } catch {
                Logger.warn("Server sign out failed, forcing local sign out: \(error)", context: "PubkyProfileManager")
            }

            if hasSharedReference {
                try await Self.clearSharedIdentitySession()
            } else if ownsIdentity {
                try Self.deletePrivateIdentityCredentials()
            }
            await Self.clearLocalState()
        }.value

        if ownsIdentity, let sourcePublicKey = publicKey {
            try SharedPubkyIdentityVault.deleteBitkitIdentity(pubky: sourcePublicKey)
        }
        clearAuthenticatedState()
    }

    func refreshSessionIfPossible(after error: Error) async -> Bool {
        await Self.withIdentityLifecycleLock {
            await self.refreshSessionIfPossibleLocked(after: error)
        }
    }

    private func refreshSessionIfPossibleLocked(after error: Error) async -> Bool {
        if let reference = try? SharedPubkyIdentityReferenceStore.load() {
            guard Self.isSessionRefreshableError(error),
                  Self.isRingAvailable()
            else {
                return false
            }

            do {
                let secretKey = try SharedPubkyIdentityVault.loadCredential(reference: reference)
                _ = try await PubkyService.signInSharedIdentity(secretKeyHex: secretKey)
                guard let signedInPublicKey = await PubkyService.currentPublicKey(),
                      SharedPubkyKeyFormat.normalizedBare(signedInPublicKey) == reference.pubky
                else {
                    throw SharedPubkyIdentityError.secretDoesNotMatchPublicKey
                }
                Logger.info("Refreshed Pubky session from source-owned identity", context: "PubkyProfileManager")
                return true
            } catch {
                Logger.warn("Failed to refresh source-owned Pubky session: \(error)", context: "PubkyProfileManager")
                await disconnectUnavailableSharedIdentityLocked()
                return false
            }
        }

        return await Self.refreshSessionIfPossible(
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
        if let reference = try SharedPubkyIdentityReferenceStore.load() {
            guard reference.sourceApp == .ring, Self.isRingAvailable() else {
                throw SharedPubkyIdentityError.sourceUnavailable
            }
            _ = try SharedPubkyIdentityVault.loadCredential(reference: reference)
        }

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

    /// Returns the active identity key only at the point of use. Shared keys are never persisted privately.
    func activeIdentitySecretKey() throws -> String {
        guard let expectedPublicKey = publicKey else {
            throw PubkyServiceError.sessionNotActive
        }

        let reference = try SharedPubkyIdentityReferenceStore.load()
        let localSecret = try Keychain.loadString(key: .pubkySecretKey)
        return try Self.resolveActiveIdentitySecretKey(
            expectedPublicKey: expectedPublicKey,
            reference: reference,
            localSecret: localSecret,
            isSourceAvailable: Self.isRingAvailable(),
            loadSharedCredential: {
                try SharedPubkyIdentityVault.loadCredential(reference: $0)
            }
        )
    }

    nonisolated static func resolveActiveIdentitySecretKey(
        expectedPublicKey: String,
        reference: SharedPubkyIdentityRefV1?,
        localSecret: String?,
        isSourceAvailable: Bool,
        loadSharedCredential: (SharedPubkyIdentityRefV1) throws -> String
    ) throws -> String {
        if let reference {
            guard localSecret?.isEmpty != false else {
                throw SharedPubkyIdentityError.provenanceConflict
            }
            guard reference.sourceApp == .ring, isSourceAvailable else {
                throw SharedPubkyIdentityError.sourceUnavailable
            }
            guard SharedPubkyKeyFormat.normalizedBare(expectedPublicKey) == reference.pubky else {
                throw SharedPubkyIdentityError.provenanceConflict
            }
            return try loadSharedCredential(reference)
        }

        guard let localSecret, !localSecret.isEmpty,
              let derivedPublicKey = try? publicKeyFromSecretKey(localSecret),
              SharedPubkyKeyFormat.normalizedBare(derivedPublicKey) ==
              SharedPubkyKeyFormat.normalizedBare(expectedPublicKey)
        else {
            throw SharedPubkyIdentityError.provenanceConflict
        }
        return localSecret
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
        if let sharedReference = try loadKeychainString(.sharedPubkyIdentityReference),
           !sharedReference.isEmpty
        {
            // The source app remains authoritative; a borrowed identity is not a portable backup.
            return nil
        }

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
        persistKeychainString: (KeychainEntryType, String) throws -> Void = { key, value in
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.failedToSave
            }
            try Keychain.upsert(key: key, data: data)
        },
        deleteKeychainValue: (KeychainEntryType) throws -> Void = {
            try Keychain.delete(key: $0)
        },
        deleteBitkitSharedIdentities: () throws -> Void = {
            try SharedPubkyIdentityVault.deleteAllBitkitIdentities()
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
        try await withIdentityLifecycleLock {
            try await restoreSessionBackupStateLocked(
                backup,
                loadKeychainString: loadKeychainString,
                persistKeychainString: persistKeychainString,
                deleteKeychainValue: deleteKeychainValue,
                deleteBitkitSharedIdentities: deleteBitkitSharedIdentities,
                clearSessionAccess: clearSessionAccess,
                signInWithSecretKey: signInWithSecretKey,
                importExternalSession: importExternalSession
            )
        }
    }

    private nonisolated static func restoreSessionBackupStateLocked(
        _ backup: PubkySessionBackupV1?,
        loadKeychainString: (KeychainEntryType) throws -> String?,
        persistKeychainString: (KeychainEntryType, String) throws -> Void,
        deleteKeychainValue: (KeychainEntryType) throws -> Void,
        deleteBitkitSharedIdentities: () throws -> Void,
        clearSessionAccess: @escaping () async -> Void,
        signInWithSecretKey: @escaping (String) async throws -> String,
        importExternalSession: @escaping (String) async throws -> String
    ) async throws {
        let localSecretKey = try loadKeychainString(.pubkySecretKey)
        let sharedReference = try loadKeychainString(.sharedPubkyIdentityReference)
        if localSecretKey?.isEmpty == false, sharedReference?.isEmpty == false {
            throw SharedPubkyIdentityError.provenanceConflict
        }

        if localSecretKey?.isEmpty == false {
            // Backup restore can replace an identity without going through AppReset.
            // Verify every Bitkit-owned mirror is gone before clearing private state.
            try deleteBitkitSharedIdentities()
        }

        await clearSessionAccess()
        try deleteKeychainValue(.paykitSession)
        try deleteKeychainValue(.pubkySecretKey)
        try deleteKeychainValue(.sharedPubkyIdentityReference)
        guard try loadKeychainString(.paykitSession) == nil,
              try loadKeychainString(.pubkySecretKey) == nil,
              try loadKeychainString(.sharedPubkyIdentityReference) == nil
        else {
            throw KeychainError.failedToDelete
        }

        switch backup?.kind {
        case .none:
            // Backups without pubky state do not carry recoverable pubky credentials.
            break
        case .localSeed:
            let secretKeyHex = try deriveLocalSecretKeyFromWalletSeed(loadKeychainString: loadKeychainString)
            try persistKeychainString(.pubkySecretKey, secretKeyHex)
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
        if let sharedReference = try SharedPubkyIdentityReferenceStore.load() {
            do {
                let sharedSecret = try SharedPubkyIdentityVault.loadCredential(reference: sharedReference)
                return await resolveSharedSessionInitialization(
                    reference: sharedReference,
                    savedSessionSecret: savedSecret,
                    sharedSecretKey: sharedSecret,
                    importSession: { try await PubkyService.importExternalSession(secret: $0) },
                    signInWithSharedSecret: { try await PubkyService.signInSharedIdentity(secretKeyHex: $0) },
                    currentPublicKey: { await PubkyService.currentPublicKey() }
                )
            } catch {
                Logger.warn("Shared Pubky session source is unavailable: \(error)", context: "PubkyProfileManager")
                try? await clearSharedIdentitySession()
                return .restorationFailed
            }
        }

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

    nonisolated static func resolveSharedSessionInitialization(
        reference: SharedPubkyIdentityRefV1,
        savedSessionSecret: String?,
        sharedSecretKey: String,
        importSession: (String) async throws -> String,
        signInWithSharedSecret: (String) async throws -> String,
        currentPublicKey: () async -> String?
    ) async -> SessionInitializationResult {
        if let savedSessionSecret, !savedSessionSecret.isEmpty {
            do {
                let restoredPublicKey = try await importSession(savedSessionSecret)
                guard SharedPubkyKeyFormat.normalizedBare(restoredPublicKey) == reference.pubky,
                      let prefixedPubky = SharedPubkyKeyFormat.prefixed(reference.pubky)
                else {
                    throw SharedPubkyIdentityError.secretDoesNotMatchPublicKey
                }
                return .restored(publicKey: prefixedPubky)
            } catch {
                Logger.warn("Shared Pubky session expired; signing in again from its source", context: "PubkyProfileManager")
            }
        }

        do {
            _ = try await signInWithSharedSecret(sharedSecretKey)
            guard let signedInPublicKey = await currentPublicKey(),
                  SharedPubkyKeyFormat.normalizedBare(signedInPublicKey) == reference.pubky,
                  let prefixedPubky = SharedPubkyKeyFormat.prefixed(reference.pubky)
            else {
                throw SharedPubkyIdentityError.secretDoesNotMatchPublicKey
            }
            return .restored(publicKey: prefixedPubky)
        } catch {
            Logger.warn("Could not restore source-owned Pubky session: \(error)", context: "PubkyProfileManager")
            return .restorationFailed
        }
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

        return try PubkyService.derivePubkySecretKey(mnemonic: mnemonic)
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
