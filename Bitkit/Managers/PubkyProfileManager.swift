import Foundation
import struct Paykit.PubkySessionBootstrapResult
import SwiftUI

enum PubkyAuthState: Equatable {
    case idle
    case authenticating
    case completingAuthentication
    case authenticated
    case error(String)
}

enum PubkyRingAuthCallback: Equatable {
    case success(nonce: String?)
    case cancel(nonce: String?)
    case error(message: String?, nonce: String?)

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

private enum PubkyProfileManagerError: LocalizedError {
    case avatarEncodingFailed

    var errorDescription: String? {
        switch self {
        case .avatarEncodingFailed:
            return "Failed to encode avatar image"
        }
    }
}

enum PubkySignupError: Error {
    case alreadySignedIn
    case inProgress
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

    enum SharedRingIdentityDiscoveryState: Equatable {
        case initial
        case loading
        case loaded
        case unavailable
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
    @Published private(set) var isProfileSetupPending: Bool
    @Published private(set) var sharedRingIdentities: [SharedPubkyIdentityOption] = []
    @Published private(set) var sharedRingIdentityDiscoveryState: SharedRingIdentityDiscoveryState = .initial

    private nonisolated static let identityLifecycleLock = PubkyIdentityLifecycleLock()
    private var isSignupInFlight = false

    nonisolated static func withIdentityLifecycleLock<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await identityLifecycleLock.withLock(operation)
    }

    init() {
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
        isProfileSetupPending = UserDefaults.standard.bool(forKey: Self.profileSetupPendingKey)
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
                try await Self.clearUnavailableSharedIdentitySession()
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

        await applySessionInitializationResult(result)
        isInitialized = true
    }

    private func applySessionInitializationResult(_ result: SessionInitializationResult) async {
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
        avatarImage: UIImage? = nil,
        loadStoredSecretKey: () async throws -> String? = {
            try await Task.detached { try Keychain.loadString(key: .pubkySecretKey) }.value
        }
    ) async throws {
        try await Self.withIdentityLifecycleLock {
            try await self.createIdentityLocked(
                name: name,
                bio: bio,
                links: links,
                tags: tags,
                existingImageUrl: existingImageUrl,
                avatarImage: avatarImage,
                loadStoredSecretKey: loadStoredSecretKey
            )
        }
    }

    private func createIdentityLocked(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String],
        existingImageUrl: String?,
        avatarImage: UIImage?,
        loadStoredSecretKey: () async throws -> String?
    ) async throws {
        try Task.checkCancellation()
        guard try SharedPubkyIdentityReferenceStore.load() == nil else {
            throw PubkyServiceError.authFailed("A Pubky identity is already recoverable")
        }

        if isProfileSetupPending, let publicKey {
            try await createProfile(
                publicKey: publicKey,
                name: name,
                bio: bio,
                links: links,
                tags: tags,
                existingImageUrl: existingImageUrl,
                avatarImage: avatarImage
            )
            return
        }

        // Resuming an interrupted setup already returned above, so reaching here creates or
        // restores an identity. A stored session that no local secret can re-sign-in belongs to
        // an external or borrowed identity: signing up would overwrite its still-recoverable
        // session secret, so refuse instead of silently replacing it.
        let hasStoredLocalSecret = try Keychain.loadString(key: .pubkySecretKey)?.isEmpty == false
        let hasStoredSession = try Keychain.loadString(key: .paykitSession)?.isEmpty == false
        guard hasStoredLocalSecret || !hasStoredSession else {
            throw PubkyServiceError.authFailed("A Pubky identity is already recoverable")
        }

        setProfileSetupPending(false)
        try await Self.completeIdentityCreation(
            loadStoredSecretKey: loadStoredSecretKey,
            signIn: { secretKeyHex in
                try await Task.detached {
                    _ = try await PubkyService.signIn(secretKeyHex: secretKeyHex)
                    return try Self.publicKeyFromSecretKey(secretKeyHex)
                }.value
            },
            signUp: {
                let (publicKey, secretKeyHex) = try await self.deriveKeys()
                _ = try await Task.detached {
                    let signupDetails: (homeserverPubky: String, signupCode: String?)
                    if let homeserverPubky = Env.e2eHomeserverPubky {
                        signupDetails = (homeserverPubky, nil)
                    } else {
                        let homegate = try await Self.fetchHomegateSignupCode()
                        signupDetails = (homegate.homeserverPubky, homegate.signupCode)
                    }

                    do {
                        return try await PubkyService.signUp(
                            secretKeyHex: secretKeyHex,
                            homeserverZ32: signupDetails.homeserverPubky,
                            signupCode: signupDetails.signupCode
                        )
                    } catch {
                        Logger.info("signUp failed (likely already registered), trying signIn: \(error)", context: "PubkyProfileManager")
                        return try await PubkyService.signIn(secretKeyHex: secretKeyHex)
                    }
                }.value
                return publicKey
            },
            createProfile: { publicKey in
                try await self.createProfile(
                    publicKey: publicKey,
                    name: name,
                    bio: bio,
                    links: links,
                    tags: tags,
                    existingImageUrl: existingImageUrl,
                    avatarImage: avatarImage
                )
            },
            discardSessionAccess: { await self.discardAbandonedSession() }
        )
    }

    static func completeIdentityCreation(
        loadStoredSecretKey: () async throws -> String?,
        signIn: (String) async throws -> String,
        signUp: () async throws -> String,
        createProfile: (String) async throws -> Void,
        discardSessionAccess: () async -> Void
    ) async throws {
        if let secretKeyHex = try await loadStoredSecretKey(), !secretKeyHex.isEmpty {
            let publicKey = try await signIn(secretKeyHex)
            try await createProfile(publicKey)
            return
        }

        let publicKey = try await signUp()
        do {
            try await createProfile(publicKey)
        } catch {
            await discardSessionAccess()
            throw error
        }
    }

    private func createProfile(
        publicKey: String,
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String],
        existingImageUrl: String?,
        avatarImage: UIImage?
    ) async throws {
        var avatarUri: String?
        if let avatarImage {
            avatarUri = try await uploadAvatar(image: avatarImage)
        }
        let imageUrl = Self.resolvedImageUrl(newImageUrl: avatarUri, existingImageUrl: existingImageUrl)

        try await writeProfile(name: name, bio: bio, imageUrl: imageUrl, links: links, tags: tags)
        Self.notifyAppStateBackupChanged()

        let createdProfile = PubkyProfile(
            publicKey: publicKey,
            name: name,
            bio: bio,
            imageUrl: imageUrl,
            links: links,
            tags: tags,
            status: nil
        )
        self.publicKey = publicKey
        authState = .authenticated
        profile = createdProfile
        cacheProfileMetadata(createdProfile)
        setProfileSetupPending(false)
        try SharedPubkyIdentityReferenceStore.delete()
        await reconcileBitkitOwnedIdentityIfNeededLocked(publicKey: publicKey)
    }

    func approveSignupAuth(request: PubkyAuthRequest) async throws {
        try await Self.withIdentityLifecycleLock {
            try await self.approveSignupAuthLocked(request: request)
        }
    }

    private func approveSignupAuthLocked(request: PubkyAuthRequest) async throws {
        guard request.isSignup, let homeserver = request.homeserverPublicKey else {
            throw PubkyServiceError.invalidAuthUrl
        }
        guard publicKey == nil, try !Self.hasStoredIdentity() else {
            throw PubkySignupError.alreadySignedIn
        }

        let (publicKey, secretKeyHex) = try await deriveKeys()
        guard self.publicKey == nil, try !Self.hasStoredIdentity() else {
            throw PubkySignupError.alreadySignedIn
        }

        try await completeSignupAuthentication(
            publicKey: publicKey,
            registerIdentity: {
                try await PubkyService.registerIdentity(
                    secretKeyHex: secretKeyHex,
                    homeserverZ32: homeserver,
                    signupCode: request.signupToken
                )
            },
            approveAuth: {
                if let authorizationUrl = request.authorizationUrl {
                    try await PubkyService.approveRingAuth(authUrl: authorizationUrl, secretKeyHex: secretKeyHex)
                }
            },
            activateIdentity: { try await PubkyService.activateRegisteredIdentity($0) }
        )
    }

    private func completeSignupAuthentication(
        publicKey: String,
        registerIdentity: () async throws -> PubkySessionBootstrapResult,
        approveAuth: @escaping () async throws -> Void,
        activateIdentity: (PubkySessionBootstrapResult) async throws -> Void,
        authorizationTimeout: Duration = .seconds(30)
    ) async throws {
        guard !isSignupInFlight else { throw PubkySignupError.inProgress }
        isSignupInFlight = true
        defer { isSignupInFlight = false }

        setProfileSetupPending(false)
        let registeredSession = try await registerIdentity()
        try await approveSignupWithTimeout(authorizationTimeout, operation: approveAuth)
        try await activateIdentity(registeredSession)

        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        self.publicKey = publicKey
        authState = .authenticated
        setProfileSetupPending(true)
        Self.notifyAppStateBackupChanged()
    }

    private func approveSignupWithTimeout(_ timeout: Duration, operation: @escaping () async throws -> Void) async throws {
        // The FFI request may ignore cancellation. Only race approval, so a late response cannot activate an abandoned signup.
        let (stream, continuation) = AsyncStream<Result<Void, Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let operationTask = Task {
            do {
                try Task.checkCancellation()
                try await operation()
                continuation.yield(.success(()))
            } catch {
                if !(error is CancellationError) {
                    Logger.warn("Pubky signup relay approval failed", context: "PubkyProfileManager")
                }
                continuation.yield(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(.failure(URLError(.timedOut)))
            } catch {}
        }

        try await withTaskCancellationHandler {
            defer {
                operationTask.cancel()
                timeoutTask.cancel()
                continuation.finish()
            }
            for await result in stream {
                try Task.checkCancellation()
                return try result.get()
            }
            throw CancellationError()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
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

    /// Orders profile deletion so it fails closed before anything is erased. Contact cleanup
    /// deletes remote records over the session a borrowed identity established, so a revoked
    /// source has to abort the flow here rather than at the deletion that follows the cleanup.
    /// Validation takes the lifecycle lock on its own; no network work runs under that lock.
    nonisolated static func deleteProfileWithContactCleanup(
        revalidateSource: () async throws -> Void,
        deleteContacts: () async -> Void,
        deleteProfile: () async throws -> Void
    ) async throws {
        try await revalidateSource()
        await deleteContacts()
        try await deleteProfile()
    }

    /// Fails closed when a source revoked a borrowed identity, before a destructive flow starts.
    /// Owned identities never read the shared vault.
    func ensureSharedIdentitySourceIsValid() async throws {
        try await Self.withIdentityLifecycleLock {
            try self.revalidateSharedIdentitySource()
        }
    }

    static func revalidateSharedIdentitySourceBeforeWrite() throws {
        try validateSharedIdentitySource(
            reference: SharedPubkyIdentityReferenceStore.load(),
            isSourceAvailable: isRingAvailable(),
            loadSharedCredential: { try SharedPubkyIdentityVault.loadCredential(reference: $0) }
        )
    }

    func deleteProfile() async throws {
        try await Self.withIdentityLifecycleLock {
            try await self.deleteProfileLocked()
        }
    }

    private func deleteProfileLocked() async throws {
        // A source can revoke a borrowed identity between session establishment and the next
        // foreground validation, so revalidate it here, under the lifecycle lock, before any
        // remote deletion or cleanup runs on a credential Ring may no longer authorize.
        try revalidateSharedIdentitySource()

        let deletedPublicKey = publicKey
        let ownsIdentity = hasLocalSecretKeyForCurrentProfile

        // Remove and verify the interoperability mirror before touching the canonical private identity.
        if ownsIdentity, let deletedPublicKey {
            try SharedPubkyIdentityVault.deleteBitkitIdentity(pubky: deletedPublicKey)
        }

        await Self.removePrivatePaykitEndpointsBestEffort(context: "PubkyProfileManager.deleteProfile")
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

        Self.clearPaykitSharingAfterProfileDeletion()
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
        guard let url = URL(string: "pubkyring://check") else {
            return false
        }

        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: - Shared Identity Discovery

    func refreshSharedRingIdentities() async {
        await refreshSharedRingIdentities(
            isRingAvailable: Self.isRingAvailable(),
            loadReferences: {
                try await Task.detached {
                    try SharedPubkyIdentityVault.list(source: .ring)
                }.value
            }
        )
    }

    func refreshSharedRingIdentities(
        isRingAvailable: Bool,
        loadReferences: () async throws -> [SharedPubkyIdentityRefV1]
    ) async {
        guard publicKey == nil else {
            sharedRingIdentities = []
            sharedRingIdentityDiscoveryState = .initial
            return
        }

        guard isRingAvailable else {
            sharedRingIdentities = []
            sharedRingIdentityDiscoveryState = .loaded
            return
        }

        sharedRingIdentityDiscoveryState = .loading

        do {
            let references = try await loadReferences()
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
            sharedRingIdentityDiscoveryState = .loaded
        } catch SharedPubkyIdentityError.missingEntitlement {
            sharedRingIdentities = []
            sharedRingIdentityDiscoveryState = .unavailable
            Logger.info("Shared Pubky Keychain entitlement is not available yet", context: "PubkyProfileManager")
        } catch {
            sharedRingIdentities = []
            sharedRingIdentityDiscoveryState = .unavailable
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
    func validateSharedIdentitySourceIfNeeded() async -> Bool {
        await Self.withIdentityLifecycleLock {
            await self.validateSharedIdentitySourceIfNeededLocked()
        }
    }

    private func validateSharedIdentitySourceIfNeededLocked() async -> Bool {
        let reference: SharedPubkyIdentityRefV1?
        do {
            reference = try SharedPubkyIdentityReferenceStore.load()
        } catch {
            if Self.shouldDisconnectSharedIdentity(after: error) {
                await disconnectUnavailableSharedIdentityLocked()
            } else {
                Logger.warn("Deferring shared Pubky reference validation: \(error)", context: "PubkyProfileManager")
            }
            return false
        }

        guard let reference else {
            if let publicKey {
                await reconcileBitkitOwnedIdentityIfNeededLocked(publicKey: publicKey)
            }
            return true
        }

        guard reference.sourceApp == .ring, Self.isRingAvailable() else {
            await disconnectUnavailableSharedIdentityLocked()
            return false
        }

        do {
            _ = try await Task.detached {
                try SharedPubkyIdentityVault.loadCredential(reference: reference)
            }.value

            let restorationResult = try await Self.retrySharedSessionRestorationIfNeeded(
                currentPublicKey: publicKey,
                restore: {
                    try await Task.detached {
                        try await Self.initializePersistedSession()
                    }.value
                }
            )
            if let restorationResult {
                initializationErrorMessage = nil
                sessionRestorationFailed = false
                await applySessionInitializationResult(restorationResult)
                isInitialized = true
            }
            return Self.canPerformPaykitMaintenance(afterSharedSessionRestoration: restorationResult)
        } catch {
            if Self.shouldDisconnectSharedIdentity(after: error) {
                Logger.warn("Shared Pubky source is no longer valid: \(error)", context: "PubkyProfileManager")
                await disconnectUnavailableSharedIdentityLocked()
            } else {
                Logger.warn("Deferring shared Pubky source validation: \(error)", context: "PubkyProfileManager")
            }
            return false
        }
    }

    nonisolated static func retrySharedSessionRestorationIfNeeded(
        currentPublicKey: String?,
        restore: () async throws -> SessionInitializationResult
    ) async throws -> SessionInitializationResult? {
        guard currentPublicKey == nil else {
            return nil
        }
        return try await restore()
    }

    static func canPerformPaykitMaintenance(afterSharedSessionRestoration result: SessionInitializationResult?) -> Bool {
        switch result {
        case nil, .some(.restored):
            return true
        case .some(.noSession), .some(.restorationFailed):
            return false
        }
    }

    nonisolated static func shouldDisconnectSharedIdentity(after error: Error) -> Bool {
        guard let error = error as? SharedPubkyIdentityError else {
            return false
        }

        switch error {
        case .invalidRecord, .invalidPublicKey, .secretDoesNotMatchPublicKey,
             .sourceUnavailable, .sourceIdentityMissing, .provenanceConflict:
            return true
        case .unavailable, .temporarilyUnavailable, .missingEntitlement:
            return false
        }
    }

    private func sharedIdentitySourceIsUnavailable() -> Bool {
        do {
            guard let reference = try SharedPubkyIdentityReferenceStore.load() else {
                return false
            }
            return reference.sourceApp != .ring || !Self.isRingAvailable()
        } catch {
            let isDefinitivelyUnavailable = Self.shouldDisconnectSharedIdentity(after: error)
            if !isDefinitivelyUnavailable {
                Logger.warn("Deferring shared Pubky source availability check: \(error)", context: "PubkyProfileManager")
            }
            return isDefinitivelyUnavailable
        }
    }

    private func disconnectUnavailableSharedIdentityLocked() async {
        sharedRingIdentities = []
        // Stop UI/event-driven identity work before remote cleanup so nothing can republish while
        // the cached session is used one final time to remove Bitkit's endpoints.
        clearAuthenticatedState()
        sessionRestorationFailed = true
        do {
            try await Self.clearUnavailableSharedIdentitySession()
        } catch {
            // Keep the durable reference as a cleanup-pending marker and retry on the next
            // launch/foreground validation. The borrowed identity remains unavailable in the UI.
            Logger.error("Failed to clear unavailable shared Pubky session: \(error)", context: "PubkyProfileManager")
        }
    }

    static func clearUnavailableSharedIdentitySession(
        removePrivatePaykitEndpoints: () async -> Bool = {
            await PubkyProfileManager.removePrivatePaykitEndpointsBestEffort(
                context: "PubkyProfileManager.sharedIdentitySourceLoss"
            )
        },
        removePublicPaykitEndpoints: () async -> Bool = {
            await PubkyProfileManager.removePublicPaykitEndpointsBestEffort(
                context: "PubkyProfileManager.sharedIdentitySourceLoss"
            )
        },
        clearSession: () async throws -> Void = {
            try await PubkyService.clearExternalSessionAccess()
        },
        clearPrivatePaykitState: () async -> Void = {
            await PrivatePaykitService.shared.closeAndClear()
        },
        clearPaykitSharingState: () async -> Void = {
            await PubkyProfileManager.clearPublicPaykitSharingState()
        },
        deleteReference: () throws -> Void = {
            try SharedPubkyIdentityReferenceStore.delete()
        }
    ) async throws {
        // Published endpoints outlive the borrowed identity, so remove them while its session is
        // still usable. Cleanup is best effort: source loss must still revoke local session access.
        _ = await removePrivatePaykitEndpoints()
        _ = await removePublicPaykitEndpoints()

        // Keep the durable reference until both identity-specific stores are gone. A session
        // failure leaves local state and its retry markers intact; a reference failure leaves an
        // empty cache and a retry marker.
        try await clearSession()
        await clearPrivatePaykitState()
        await clearPaykitSharingState()
        try deleteReference()
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
        // Mirroring intentionally ignores the Paykit UI flag: existing profiles must become
        // discoverable to Pubky Ring after an upgrade even when Bitkit's Paykit UI is hidden.
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

    // MARK: - Legacy Ring Callbacks

    /// Old callbacks remain recognized so they cannot fall through to payment handling.
    func handleAuthCallback(_ callback: PubkyRingAuthCallback) {
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
    }

    private func discardAbandonedSession() async {
        await discardAbandonedSession(
            revokeSessionAccess: {
                try await Task.detached {
                    try await PubkyService.signOut()
                }.value
            },
            forgetSessionAccess: {
                try await Task.detached {
                    try await PubkyService.forgetSessionAccess()
                }.value
            }
        )
    }

    private func discardAbandonedSession(
        revokeSessionAccess: @escaping () async throws -> Void,
        forgetSessionAccess: @escaping () async throws -> Void
    ) async {
        do {
            try await revokeSessionAccess()
        } catch {
            Logger.warn("Failed to revoke abandoned Pubky session: \(error)", context: "PubkyProfileManager")
            do {
                try await forgetSessionAccess()
            } catch {
                Logger.warn("Failed to forget abandoned Pubky session access: \(error)", context: "PubkyProfileManager")
            }
        }
    }

    func finalizeAuthentication() {
        guard case .completingAuthentication = authState else { return }
        authState = .authenticated
    }

    #if DEBUG
        func completeSignupAuthenticationForTesting(
            publicKey: String,
            registerIdentity: () async throws -> PubkySessionBootstrapResult,
            approveAuth: @escaping () async throws -> Void,
            activateIdentity: (PubkySessionBootstrapResult) async throws -> Void,
            authorizationTimeout: Duration = .seconds(30)
        ) async throws {
            try await completeSignupAuthentication(
                publicKey: publicKey,
                registerIdentity: registerIdentity,
                approveAuth: approveAuth,
                activateIdentity: activateIdentity,
                authorizationTimeout: authorizationTimeout
            )
        }

        func discardAbandonedSessionForTesting(
            revokeSessionAccess: @escaping () async throws -> Void,
            forgetSessionAccess: @escaping () async throws -> Void
        ) async {
            await discardAbandonedSession(
                revokeSessionAccess: revokeSessionAccess,
                forgetSessionAccess: forgetSessionAccess
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
        do {
            try await PubkyService.forgetSessionAccess()
        } catch {
            Logger.warn("Failed to forget local Pubky session access: \(error)", context: "PubkyProfileManager")
        }
        try? SharedPubkyIdentityReferenceStore.delete()
        await clearLocalAppState()
    }

    private static func clearLocalAppState() async {
        await PrivatePaykitService.shared.closeAndClear()
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments()
        await PubkyImageCache.shared.clear()
        UserDefaults.standard.removeObject(forKey: cachedNameKey)
        UserDefaults.standard.removeObject(forKey: cachedImageUriKey)
        UserDefaults.standard.removeObject(forKey: profileSetupPendingKey)
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

    @discardableResult
    static func removePublicPaykitEndpointsBestEffort(context: String) async -> Bool {
        do {
            try await removePublicPaykitEndpoints(context: context)
            PublicPaykitService.setCleanupPending(false)
            return true
        } catch {
            PublicPaykitService.setCleanupPending(true)
            return false
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

    @discardableResult
    static func removePrivatePaykitEndpointsBestEffort(context: String) async -> Bool {
        do {
            try await removePrivatePaykitEndpoints(context: context)
            PrivatePaykitService.setContactSharingCleanupPending(false)
            return true
        } catch {
            PrivatePaykitService.setContactSharingCleanupPending(true)
            return false
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

        let publicSharingEnabled = UserDefaults.standard.bool(forKey: PublicPaykitService.publishingEnabledKey)
        let privateSharingEnabled = UserDefaults.standard.bool(forKey: PrivatePaykitService.publishingEnabledKey)

        do {
            try await Task.detached {
                if cleanPrivatePaykitEndpoints {
                    try await Self.removePrivatePaykitEndpoints(context: "PubkyProfileManager.signOut")
                }
                await Self.removePublicPaykitEndpointsBestEffort(context: "PubkyProfileManager.signOut")
                try await PubkyService.signOut()

                if hasSharedReference {
                    try await Self.clearSharedIdentitySession()
                } else if ownsIdentity {
                    try Self.deletePrivateIdentityCredentials()
                }
                await Self.clearLocalAppState()
            }.value
        } catch {
            Self.markPaykitReconciliationPendingAfterFailedSignOut(
                publicSharingEnabled: publicSharingEnabled,
                privateSharingEnabled: privateSharingEnabled
            )
            throw error
        }

        if ownsIdentity, let sourcePublicKey = publicKey {
            try SharedPubkyIdentityVault.deleteBitkitIdentity(pubky: sourcePublicKey)
        }

        setProfileSetupPending(false)
        clearAuthenticatedState()
    }

    static func markPaykitReconciliationPendingAfterFailedSignOut(
        publicSharingEnabled: Bool,
        privateSharingEnabled: Bool,
        setPublicReconciliationPending: (Bool) -> Void = PublicPaykitService.setCleanupPending,
        setPrivateReconciliationPending: (Bool) -> Void = PrivatePaykitService.setContactSharingCleanupPending
    ) {
        if publicSharingEnabled || privateSharingEnabled {
            setPublicReconciliationPending(true)
        }
        if privateSharingEnabled {
            setPrivateReconciliationPending(true)
        }
    }

    static func clearPaykitSharingAfterProfileDeletion(
        defaults: UserDefaults = .standard,
        setPublicReconciliationPending: (Bool) -> Void = PublicPaykitService.setCleanupPending
    ) {
        let hadPublishedState = defaults.bool(forKey: PublicPaykitService.publishingEnabledKey) ||
            defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        if hadPublishedState {
            setPublicReconciliationPending(true)
        }
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
                if Self.shouldDisconnectSharedIdentity(after: error) {
                    await disconnectUnavailableSharedIdentityLocked()
                }
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
    private static let profileSetupPendingKey = "pubky_profile_setup_pending"

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

    private func setProfileSetupPending(_ pending: Bool) {
        isProfileSetupPending = pending
        UserDefaults.standard.set(pending, forKey: Self.profileSetupPendingKey)
    }

    private func clearAuthenticatedState() {
        publicKey = nil
        profile = nil
        authState = .idle
        sharedRingIdentities = []
        sharedRingIdentityDiscoveryState = .initial
        clearCachedProfileMetadata()
    }

    private func activeSessionSecret() throws -> String {
        try revalidateSharedIdentitySource()

        guard let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else {
            throw PubkyServiceError.sessionNotActive
        }
        return sessionSecret
    }

    /// Re-reads a borrowed credential just in time. Owned identities never touch the shared vault.
    private func revalidateSharedIdentitySource() throws {
        try Self.validateSharedIdentitySource(
            reference: SharedPubkyIdentityReferenceStore.load(),
            isSourceAvailable: Self.isRingAvailable(),
            loadSharedCredential: { try SharedPubkyIdentityVault.loadCredential(reference: $0) }
        )
    }

    nonisolated static func validateSharedIdentitySource(
        reference: SharedPubkyIdentityRefV1?,
        isSourceAvailable: Bool,
        loadSharedCredential: (SharedPubkyIdentityRefV1) throws -> String
    ) throws {
        guard let reference else {
            return
        }
        guard reference.sourceApp == .ring, isSourceAvailable else {
            throw SharedPubkyIdentityError.sourceUnavailable
        }
        // Loading re-derives the public key from the source record and fails closed when the
        // source has removed, rotated or invalidated the identity Bitkit borrowed.
        _ = try loadSharedCredential(reference)
    }

    // MARK: - Session & Backup Helpers

    var isAuthenticated: Bool {
        publicKey != nil
    }

    var hasLocalSecretKeyForCurrentProfile: Bool {
        Self.hasLocalSecretKey(for: publicKey)
    }

    nonisolated static func hasStoredIdentity() throws -> Bool {
        // A source-owned reference is a recoverable identity too: signup must never create a
        // local identity while a borrowed one is connected or still pending cleanup.
        for key in [KeychainEntryType.paykitSession, .pubkySecretKey, .sharedPubkyIdentityReference] {
            if let value = try Keychain.loadString(key: key), !value.isEmpty {
                return true
            }
        }
        return false
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
        forgetSessionAccess: @escaping () async throws -> Void = {
            try await PubkyService.forgetSessionAccess()
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
                forgetSessionAccess: forgetSessionAccess,
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
        forgetSessionAccess: @escaping () async throws -> Void,
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

        do {
            try await forgetSessionAccess()
        } catch {
            Logger.warn("Failed to forget existing Pubky session before restore: \(error)", context: "PubkyProfileManager")
        }
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
                if shouldDisconnectSharedIdentity(after: error) {
                    try? await clearUnavailableSharedIdentitySession()
                }
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
