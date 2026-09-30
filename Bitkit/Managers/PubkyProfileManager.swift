import Foundation
import struct Paykit.PubkySessionBootstrapResult
import SwiftUI

enum PubkyAuthState: Equatable {
    case idle
    case authenticated
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

@MainActor
class PubkyProfileManager: ObservableObject {
    enum SessionInitializationResult: Equatable {
        case noSession
        case restored(publicKey: String)
        case restorationFailed
    }

    typealias RemoteProfileResolver = @Sendable (String) async throws -> PubkyProfile

    private enum SessionInitializationMode {
        case userVisible
        case automaticRecovery
    }

    @Published var authState: PubkyAuthState = .idle
    @Published var profile: PubkyProfile?
    @Published var publicKey: String?
    @Published var isLoadingProfile = false
    @Published private(set) var isRestoringSession = false
    @Published var isInitialized = false
    @Published var initializationErrorMessage: String?
    @Published var sessionRestorationFailed = false
    @Published var adoptedSourceLost = false
    @Published private(set) var cachedName: String?
    @Published private(set) var cachedImageUri: String?
    /// The pubky the cached name and avatar were written for. Nil for a cache written before the owner was stored.
    @Published private var cachedProfileOwner: String?
    @Published private(set) var isProfileSetupPending: Bool
    /// Public profiles found for the Pubky Ring rows on the choice screen, keyed by normalized pubky. Display-only.
    @Published private(set) var ringIdentityProfiles: [String: PubkyProfile] = [:]
    /// Covers a Ring adoption from before its reference is written, which already makes `hasExistingIdentity` true, until
    /// it succeeds, fails or is cancelled.
    @Published private(set) var isAdoptingRingIdentity = false

    private var isSignupInFlight = false
    private var initializationTask: Task<Void, Never>?
    private static var isRingAdoptionInFlight = false
    private static var sessionRevision = UUID()
    private static var sessionMutationCount = 0
    private let remoteProfileResolver: RemoteProfileResolver
    /// Bumped whenever `profile` is written or the identity changes, so a remote read that started earlier is dropped.
    private var profileWriteGeneration = 0
    /// Ring rows whose lookup found nothing. The SDK reports a missing record and an offline failure alike, so a miss
    /// only stops repeat lookups and must never drive sign-up or profile-setup decisions.
    private var ringIdentityMisses: Set<String> = []
    private var ringIdentityLookups: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    private static func beginSessionMutation() {
        sessionRevision = UUID()
        sessionMutationCount += 1
    }

    private static func endSessionMutation() {
        sessionMutationCount -= 1
    }

    init(remoteProfileResolver: @escaping RemoteProfileResolver = { try await PubkyProfileManager.resolveRemoteProfile(publicKey: $0) }) {
        self.remoteProfileResolver = remoteProfileResolver
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
        cachedProfileOwner = UserDefaults.standard.string(forKey: Self.cachedProfileOwnerKey)
        isProfileSetupPending = UserDefaults.standard.bool(forKey: Self.profileSetupPendingKey)
    }

    var hasExistingIdentity: Bool {
        if isAuthenticated || cachedName != nil { return true }
        // Unreadable credentials must not be treated as a new identity.
        return (try? Self.hasStoredIdentity()) != false
    }

    // MARK: - Initialization & Session Restoration

    /// Initializes Paykit and restores any persisted session.
    func initialize(
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult = {
            try await PubkyProfileManager.initializePersistedSession()
        }
    ) async {
        await initialize(mode: .userVisible, initializeSession: initializeSession)
    }

    private func initialize(
        mode: SessionInitializationMode,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        if let initializationTask {
            await initializationTask.value
            return
        }
        guard Self.sessionMutationCount == 0 else { return }
        isRestoringSession = true
        let task = Task {
            defer {
                initializationTask = nil
                isRestoringSession = false
            }
            guard Self.sessionMutationCount == 0 else { return }
            await initializeSessionState(mode: mode, initializeSession: initializeSession)
        }
        initializationTask = task
        await task.value
    }

    /// Retry saved credentials after startup or connectivity failures without replacing active identity work.
    func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool = { try PubkyProfileManager.hasStoredIdentity() },
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult = {
            try await PubkyProfileManager.initializePersistedSession()
        }
    ) async {
        if let initializationTask {
            await initializationTask.value
        }
        guard !Task.isCancelled, publicKey == nil, authState == .idle, Self.sessionMutationCount == 0 else { return }
        do {
            guard try hasStoredIdentity() else { return }
            await initialize(mode: .automaticRecovery, initializeSession: initializeSession)
        } catch {
            Logger.warn("Unable to read saved Pubky identity for recovery: \(error)", context: "PubkyProfileManager")
        }
    }

    func retrySessionRestoration(
        retryDelay: Duration = .seconds(10),
        jitter: () -> Double = { Double.random(in: 0.8 ... 1.2) },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        hasStoredIdentity: () throws -> Bool = { try PubkyProfileManager.hasStoredIdentity() },
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult = {
            try await PubkyProfileManager.initializePersistedSession()
        }
    ) async {
        // A usable connection can return without a new network-path event.
        let maximumDelay = Duration.seconds(180)
        var delay = retryDelay
        while !Task.isCancelled {
            await restoreSessionIfNeeded(hasStoredIdentity: hasStoredIdentity, initializeSession: initializeSession)
            guard !isAuthenticated, (try? hasStoredIdentity()) != false else { return }
            do {
                try await sleep(min(delay * jitter(), maximumDelay))
            } catch {
                return
            }
            delay = min(delay * 2, maximumDelay)
        }
    }

    private func initializeSessionState(
        mode: SessionInitializationMode,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        let revision = Self.sessionRevision
        if case .userVisible = mode {
            isInitialized = false
            initializationErrorMessage = nil
            sessionRestorationFailed = false
        }

        let result: SessionInitializationResult
        do {
            result = try await Task.detached {
                try await initializeSession()
            }.value
        } catch {
            guard revision == Self.sessionRevision else {
                isInitialized = true
                return
            }
            Logger.error("Failed to initialize paykit: \(error)", context: "PubkyProfileManager")
            authState = .idle
            if case .userVisible = mode {
                initializationErrorMessage = error.localizedDescription
            }
            return
        }

        guard revision == Self.sessionRevision else {
            isInitialized = true
            return
        }
        initializationErrorMessage = nil
        Self.publishOwnSharedRecord()

        switch result {
        case .noSession:
            clearAuthenticatedState()
            sessionRestorationFailed = false
            Logger.debug("No saved paykit session found", context: "PubkyProfileManager")
        case let .restored(pk):
            reloadCachedProfileMetadata()
            publicKey = pk
            authState = .authenticated
            sessionRestorationFailed = false
            Logger.info("Paykit session restored for \(pk)", context: "PubkyProfileManager")
            Task { await loadProfile() }
        case .restorationFailed:
            clearAuthenticatedState(clearCachedProfile: false)
            if case .userVisible = mode {
                sessionRestorationFailed = true
            }
        }

        await checkAdoptedSource()
        isInitialized = true
    }

    /// Drops the adopted identity when its owner app has provably removed the shared record.
    func checkAdoptedSource() async {
        guard let adopted = AdoptedPubkyReference.current,
              SharedPubkyKeychain.isDefinitelyMissing(sourceApp: adopted.sourceApp, pubky: adopted.pubky)
        else { return }

        clearAuthenticatedState()
        await Self.clearLocalState()
        adoptedSourceLost = true
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

    /// The public key of the identity in use: the adopted pubky when one exists, otherwise the wallet-derived one.
    func activePublicKey() async throws -> String {
        if let adopted = AdoptedPubkyReference.current,
           let publicKey = PubkyPublicKeyFormat.normalized(adopted.pubky)
        {
            return publicKey
        }

        return try await deriveKeys().0
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
            await Task.detached { PubkyProfileManager.activeSecretKeyHex() }.value
        }
    ) async throws {
        Self.beginSessionMutation()
        defer { Self.endSessionMutation() }
        if let publicKey, isProfileSetupPending || AdoptedPubkyReference.current != nil {
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
                    do {
                        return try await Self.signUpToHomeserver(secretKeyHex: secretKeyHex)
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

        Self.publishOwnSharedRecord()
    }

    /// Publishes Bitkit's own pubky into the shared keychain group so Pubky Ring can offer it. Best effort.
    nonisolated static func publishOwnSharedRecord() {
        Task.detached {
            do {
                guard let secretKeyHex = try Keychain.loadString(key: .pubkySecretKey), !secretKeyHex.isEmpty else {
                    return
                }
                let pubky = try SharedPubkyKeychain.derivedPubky(fromSecretKeyHex: secretKeyHex)
                SharedPubkyKeychain.publishOwn(pubky: pubky, secretKeyHex: secretKeyHex)
            } catch {
                Logger.warn("Failed to publish the shared pubky record: \(error)", context: "PubkyProfileManager")
            }
        }
    }

    private nonisolated static func isUnpublishedIdentity(publicKey: String) async -> Bool {
        do {
            return try await !PubkyService.hasIdentityRecord(publicKey: publicKey)
        } catch {
            Logger.warn("Failed to check the Pubky Ring key's identity record: \(error)", context: "PubkyProfileManager")
            return false
        }
    }

    private nonisolated static func signUpToHomeserver(secretKeyHex: String) async throws -> String {
        let signupDetails: (homeserverPubky: String, signupCode: String?)
        if let homeserverPubky = Env.e2eHomeserverPubky {
            signupDetails = (homeserverPubky, nil)
        } else {
            let homegate = try await fetchHomegateSignupCode()
            signupDetails = (homegate.homeserverPubky, homegate.signupCode)
        }

        return try await PubkyService.signUp(
            secretKeyHex: secretKeyHex,
            homeserverZ32: signupDetails.homeserverPubky,
            signupCode: signupDetails.signupCode
        )
    }

    /// Signs in with a pubky owned by Pubky Ring. The secret is read just-in-time and never persisted here.
    func adoptRingIdentity(
        pubky: String,
        loadSecret: (String, String) -> String? = SharedPubkyKeychain.loadSecret,
        signIn: @escaping @Sendable (String) async throws -> Void = { try await PubkyProfileManager.signInWithRingKey($0) },
        fetchProfile: (@Sendable (String) async -> PubkyProfile?)? = nil
    ) async throws -> PubkyProfile? {
        guard !Self.isRingAdoptionInFlight else {
            throw PubkyServiceError.authFailed("Pubky Ring sign-in already in progress")
        }
        Self.isRingAdoptionInFlight = true
        Self.beginSessionMutation()
        defer {
            Self.isRingAdoptionInFlight = false
            isAdoptingRingIdentity = false
            Self.endSessionMutation()
        }
        let sourceApp = SharedPubkyKeychain.ringSourceApp
        guard let secretKeyHex = loadSecret(sourceApp, pubky) else {
            throw PubkyServiceError.authFailed("Pubky Ring key unavailable")
        }

        let previousAdoptedIdentity = AdoptedPubkyReference.current
        isAdoptingRingIdentity = true
        AdoptedPubkyReference.current = (sourceApp, pubky)
        let adoptedPublicKey: String
        do {
            adoptedPublicKey = try await Task.detached {
                let publicKey = try Self.publicKeyFromSecretKey(secretKeyHex)
                try await signIn(secretKeyHex)
                return publicKey
            }.value
        } catch {
            if let currentAdoptedIdentity = AdoptedPubkyReference.current,
               currentAdoptedIdentity.sourceApp == sourceApp,
               currentAdoptedIdentity.pubky == pubky
            {
                AdoptedPubkyReference.current = previousAdoptedIdentity
            }
            throw error
        }

        return try await completeRingAdoption(publicKey: adoptedPublicKey, fetchProfile: fetchProfile)
    }

    private func completeRingAdoption(
        publicKey adoptedPublicKey: String,
        fetchProfile: (@Sendable (String) async -> PubkyProfile?)? = nil
    ) async throws -> PubkyProfile? {
        invalidateProfileLoads()
        reloadCachedProfileMetadata()
        publicKey = adoptedPublicKey
        authState = .authenticated
        Self.notifyAppStateBackupChanged()

        let adoptionRevision = Self.sessionRevision
        // Read only after sign-in: when lookups are contended, the tapped row's result lands after the tap. Only a found
        // row profile for this key is reused; anything else takes the fetch that decides profile setup.
        let rowKey = PubkyPublicKeyFormat.normalized(adoptedPublicKey)
        var adoptedProfile = rowKey.flatMap { ringIdentityProfiles[$0] }
        if adoptedProfile == nil, let rowKey, let lookup = ringIdentityLookups[rowKey], !lookup.task.isCancelled {
            // The row's lookup is already ahead of a fresh fetch for the same key.
            await lookup.task.value
            adoptedProfile = ringIdentityProfiles[rowKey]
        }
        let reusesRowProfile = PubkyPublicKeyFormat.matches(adoptedProfile?.publicKey, adoptedPublicKey)
        if !reusesRowProfile {
            adoptedProfile = if let fetchProfile {
                await fetchProfile(adoptedPublicKey)
            } else {
                await fetchRemoteProfile(publicKey: adoptedPublicKey)
            }
        }
        guard adoptionRevision == Self.sessionRevision, publicKey == adoptedPublicKey else {
            throw CancellationError()
        }
        clearRingIdentityProfiles()

        setProfileSetupPending(adoptedProfile == nil)
        if let adoptedProfile {
            commitProfile(adoptedProfile)
        }
        if reusesRowProfile {
            // A row profile can be from earlier in the session. The refresh runs behind navigation, never decides profile
            // setup, and is dropped if a newer profile write lands first.
            Task { await loadProfile() }
        }
        return adoptedProfile
    }

    private nonisolated static func signInWithRingKey(_ secretKeyHex: String) async throws {
        let publicKey = try publicKeyFromSecretKey(secretKeyHex)
        do {
            _ = try await PubkyService.signIn(secretKeyHex: secretKeyHex)
        } catch {
            Logger.warn("Sign-in with the Pubky Ring key failed: \(error)", context: "PubkyProfileManager")
            // Signup rewrites the homeserver record, so only a Ring key that was never published signs up.
            guard await Self.isUnpublishedIdentity(publicKey: publicKey) else { throw error }
            _ = try await Self.signUpToHomeserver(secretKeyHex: secretKeyHex)
        }
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
        commitProfile(createdProfile)
        setProfileSetupPending(false)
    }

    func approveSignupAuth(request: PubkyAuthRequest) async throws {
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
        Self.publishOwnSharedRecord()
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
        Self.beginSessionMutation()
        defer {
            isSignupInFlight = false
            Self.endSessionMutation()
        }

        setProfileSetupPending(false)
        let registeredSession = try await registerIdentity()
        try await approveSignupWithTimeout(authorizationTimeout, operation: approveAuth)
        try await activateIdentity(registeredSession)

        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        reloadCachedProfileMetadata()
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
        commitProfile(updatedProfile)
    }

    func deleteProfile() async throws {
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

        invalidateProfileLoads()
        Self.clearPaykitSharingAfterProfileDeletion()
        try await signOut(cleanPrivatePaykitEndpoints: false)
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

        func completeRingAdoptionForTesting(publicKey: String) async throws -> PubkyProfile? {
            try await completeRingAdoption(publicKey: publicKey)
        }

        func clearAuthenticatedStateForTesting() {
            clearAuthenticatedState()
        }
    #endif

    // MARK: - Profile

    func loadProfile() async {
        guard let pk = publicKey, !isLoadingProfile else { return }

        isLoadingProfile = true
        let generation = profileWriteGeneration
        let resolve = remoteProfileResolver

        do {
            let loadedProfile = try await Task.detached {
                try await resolve(pk)
            }.value
            if publicKey == pk, profileWriteGeneration == generation {
                profile = loadedProfile
                cacheProfileMetadata(loadedProfile)
            }
        } catch {
            Logger.error("Failed to load profile: \(error)", context: "PubkyProfileManager")
        }

        isLoadingProfile = false
    }

    /// Fetch a remote profile by public key. Returns nil if no profile exists.
    func fetchRemoteProfile(publicKey: String) async -> PubkyProfile? {
        do {
            return try await remoteProfileResolver(publicKey)
        } catch {
            Logger.debug("No remote profile found for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)", context: "PubkyProfileManager")
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

    /// Sets a profile this device just wrote or chose, dropping any remote read that started before it.
    private func commitProfile(_ newProfile: PubkyProfile) {
        invalidateProfileLoads()
        profile = newProfile
        cacheProfileMetadata(newProfile)
    }

    private func invalidateProfileLoads() {
        profileWriteGeneration += 1
    }

    // MARK: - Pubky Ring Choice Rows

    /// Looks up the rows that have no cached result and no live lookup. Cancelling the caller cancels the lookups it
    /// started, so a screen the user has left stops queueing for read slots.
    func loadRingIdentityProfiles(_ pubkys: [String]) async {
        let lookups = Set(pubkys.compactMap(PubkyPublicKeyFormat.normalized))
            .filter { needsRingIdentityLookup($0) }
            .map { startRingIdentityLookup($0) }

        await withTaskCancellationHandler {
            for lookup in lookups {
                await lookup.value
            }
        } onCancel: {
            lookups.forEach { $0.cancel() }
        }
    }

    /// Forgets the misses on returning to the app, since the user may have just published that pubky in Pubky Ring.
    func forgetRingIdentityMisses() {
        ringIdentityMisses.removeAll()
    }

    /// Stops every row lookup but `pubky`'s, whose result adoption can still reuse if it lands before sign-in finishes.
    /// A stopped lookup records no miss, so the next load looks that row up again.
    func cancelRingIdentityLookups(except pubky: String) {
        let keptKey = PubkyPublicKeyFormat.normalized(pubky)
        for (key, lookup) in ringIdentityLookups where key != keptKey {
            lookup.task.cancel()
        }
    }

    private func needsRingIdentityLookup(_ key: String) -> Bool {
        guard ringIdentityProfiles[key] == nil, !ringIdentityMisses.contains(key) else { return false }
        // A cancelled lookup records no miss when it fails, so it cannot stand in for a live one.
        return ringIdentityLookups[key]?.task.isCancelled ?? true
    }

    private func startRingIdentityLookup(_ key: String) -> Task<Void, Never> {
        let id = UUID()
        let resolve = remoteProfileResolver
        let task = Task {
            var foundProfile: PubkyProfile?
            do {
                foundProfile = try await resolve(key)
            } catch {
                Logger.debug("No profile found for Pubky Ring key \(PubkyPublicKeyFormat.redacted(key)): \(error)", context: "PubkyProfileManager")
            }
            finishRingIdentityLookup(key, id: id, foundProfile: foundProfile)
        }
        ringIdentityLookups[key] = (id, task)
        return task
    }

    /// Runs on the lookup's own task, so `Task.isCancelled` is that lookup's cancellation.
    private func finishRingIdentityLookup(_ key: String, id: UUID, foundProfile: PubkyProfile?) {
        // A newer lookup or a cache clear has replaced this one, so its result may be stale.
        guard ringIdentityLookups[key]?.id == id else { return }
        ringIdentityLookups[key] = nil

        if let foundProfile {
            ringIdentityProfiles[key] = foundProfile
        } else if !Task.isCancelled {
            ringIdentityMisses.insert(key)
        }
    }

    private func clearRingIdentityProfiles() {
        ringIdentityLookups.values.forEach { $0.task.cancel() }
        ringIdentityLookups.removeAll()
        ringIdentityMisses.removeAll()
        ringIdentityProfiles.removeAll()
    }

    // MARK: - Sign Out

    static func clearLocalState() async {
        beginSessionMutation()
        defer { endSessionMutation() }
        do {
            try await PubkyService.forgetSessionAccess()
        } catch {
            Logger.warn("Failed to forget local Pubky session access: \(error)", context: "PubkyProfileManager")
            try? PubkySessionAccessTeardown.clear { try Keychain.delete(key: $0) }
        }
        await clearLocalAppState()
    }

    private static func clearLocalAppState() async {
        SharedPubkyKeychain.removeAllOwn()
        AdoptedPubkyReference.current = nil
        await PrivatePaykitService.shared.closeAndClear()
        await PrivatePaykitAddressReservationStore.shared.clearContactAssignments()
        await PubkyImageCache.shared.clear()
        UserDefaults.standard.removeObject(forKey: cachedNameKey)
        UserDefaults.standard.removeObject(forKey: cachedImageUriKey)
        UserDefaults.standard.removeObject(forKey: cachedProfileOwnerKey)
        UserDefaults.standard.removeObject(forKey: profileSetupPendingKey)
        ContactsManager.restoreContactProfileOverrides(nil)
        clearPublicPaykitSharingState()
        notifyAppStateBackupChanged()
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
        try await signOut(cleanPrivatePaykitEndpoints: true)
    }

    private func signOut(cleanPrivatePaykitEndpoints: Bool) async throws {
        try await signOut {
            if cleanPrivatePaykitEndpoints {
                try await Self.removePrivatePaykitEndpoints(context: "PubkyProfileManager.signOut")
            }
            await Self.removePublicPaykitEndpointsBestEffort(context: "PubkyProfileManager.signOut")
            try await PubkyService.signOut()
        }
    }

    func signOut(performSessionCleanup: @escaping @Sendable () async throws -> Void) async throws {
        Self.beginSessionMutation()
        defer { Self.endSessionMutation() }
        let publicSharingEnabled = UserDefaults.standard.bool(forKey: PublicPaykitService.publishingEnabledKey)
        let privateSharingEnabled = UserDefaults.standard.bool(forKey: PrivatePaykitService.publishingEnabledKey)

        do {
            try await Task.detached {
                try await performSessionCleanup()
                await Self.clearLocalAppState()
            }.value
        } catch {
            Self.markPaykitReconciliationPendingAfterFailedSignOut(
                publicSharingEnabled: publicSharingEnabled,
                privateSharingEnabled: privateSharingEnabled
            )
            throw error
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
        await Self.refreshSessionIfPossible(
            after: error,
            loadKeychainString: { try Keychain.loadString(key: $0) },
            signInWithSecretKey: { try await PubkyService.signIn(secretKeyHex: $0) }
        )
    }

    // MARK: - Cached Profile Metadata

    private static let cachedNameKey = "pubky_profile_name"
    private static let cachedImageUriKey = "pubky_profile_image_uri"
    private static let cachedProfileOwnerKey = "pubky_profile_owner"
    private static let profileSetupPendingKey = "pubky_profile_setup_pending"

    var displayName: String? {
        profile?.name ?? cachedName
    }

    var displayImageUri: String? {
        profile?.imageUrl ?? cachedImageUri
    }

    /// The cached name and avatar for the signed-in pubky, shown read-only while its profile loads. It has no bio, links
    /// or tags, so it must never stand in for `profile`. Nil before initialization and when the cache belongs to
    /// another pubky or has no recorded owner.
    var cachedProfilePreview: PubkyProfile? {
        guard isInitialized,
              let publicKey,
              let cachedName,
              PubkyPublicKeyFormat.matches(cachedProfileOwner, publicKey)
        else { return nil }

        return .forDisplay(publicKey: publicKey, name: cachedName, imageUrl: cachedImageUri)
    }

    private func cacheProfileMetadata(_ profile: PubkyProfile) {
        cachedName = profile.name
        cachedImageUri = profile.imageUrl
        cachedProfileOwner = profile.publicKey
        UserDefaults.standard.set(profile.name, forKey: Self.cachedNameKey)
        UserDefaults.standard.set(profile.imageUrl, forKey: Self.cachedImageUriKey)
        UserDefaults.standard.set(profile.publicKey, forKey: Self.cachedProfileOwnerKey)
    }

    static func clearCachedIdentityMetadata() {
        UserDefaults.standard.removeObject(forKey: cachedNameKey)
        UserDefaults.standard.removeObject(forKey: cachedImageUriKey)
        UserDefaults.standard.removeObject(forKey: cachedProfileOwnerKey)
        ContactsManager.restoreContactProfileOverrides(nil)
    }

    private func reloadCachedProfileMetadata() {
        profile = nil
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
        cachedProfileOwner = UserDefaults.standard.string(forKey: Self.cachedProfileOwnerKey)
    }

    private func clearCachedProfileMetadata() {
        cachedName = nil
        cachedImageUri = nil
        cachedProfileOwner = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedNameKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedImageUriKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedProfileOwnerKey)
    }

    private func setProfileSetupPending(_ pending: Bool) {
        isProfileSetupPending = pending
        UserDefaults.standard.set(pending, forKey: Self.profileSetupPendingKey)
    }

    private func clearAuthenticatedState(clearCachedProfile: Bool = true) {
        // Automatic recovery also lands here while nothing is signed in, which must not discard the choice rows.
        let wasAuthenticated = isAuthenticated
        invalidateProfileLoads()
        publicKey = nil
        profile = nil
        authState = .idle
        if clearCachedProfile {
            clearCachedProfileMetadata()
        }
        if wasAuthenticated {
            clearRingIdentityProfiles()
        }
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

    nonisolated static func hasStoredIdentity(
        adopted: (sourceApp: String, pubky: String)? = AdoptedPubkyReference.current
    ) throws -> Bool {
        // The next launch signs in again with an adopted Ring key, so its reference counts as an identity.
        if adopted != nil {
            return true
        }

        for key in [KeychainEntryType.paykitSession, .pubkySecretKey] {
            if let value = try Keychain.loadString(key: key), !value.isEmpty {
                return true
            }
        }
        return false
    }

    /// The secret key to sign with: Bitkit's own if it has one, otherwise the adopted app's, read just-in-time.
    nonisolated static func activeSecretKeyHex(
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        },
        adopted: (sourceApp: String, pubky: String)? = AdoptedPubkyReference.current,
        loadSharedSecret: (String, String) -> String? = SharedPubkyKeychain.loadSecret
    ) -> String? {
        if let secretKeyHex = try? loadKeychainString(.pubkySecretKey), !secretKeyHex.isEmpty {
            return secretKeyHex
        }

        guard let adopted else {
            return nil
        }

        return loadSharedSecret(adopted.sourceApp, adopted.pubky)
    }

    nonisolated static func hasLocalSecretKey(for publicKey: String?) -> Bool {
        guard let publicKey,
              let secretKeyHex = activeSecretKeyHex(),
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
        },
        adopted: (sourceApp: String, pubky: String)? = AdoptedPubkyReference.current
    ) throws -> PubkySessionBackupV1? {
        // A foreign key stays with its owner, so an adopted identity has nothing to back up.
        guard adopted == nil else {
            return nil
        }

        guard let secretKeyHex = try loadKeychainString(.pubkySecretKey), !secretKeyHex.isEmpty else {
            return nil
        }

        return PubkySessionBackupV1(kind: .localSeed)
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
        removeOwnSharedRecords: () -> Void = {
            SharedPubkyKeychain.removeAllOwn()
        },
        forgetSessionAccess: @escaping () async throws -> Void = {
            try await PubkyService.forgetSessionAccess()
        },
        signInWithSecretKey: @escaping (String) async throws -> String = {
            try await PubkyService.signIn(secretKeyHex: $0)
        }
    ) async throws {
        await beginSessionMutation()
        do {
            do {
                try await forgetSessionAccess()
            } catch {
                Logger.warn("Failed to forget existing Pubky session before restore: \(error)", context: "PubkyProfileManager")
            }

            switch backup?.kind {
            case .none:
                // No kind, or one this version no longer restores: the backup carries no usable pubky credentials.
                try? deleteKeychainValue(.paykitSession)
                try? deleteKeychainValue(.pubkySecretKey)
                removeOwnSharedRecords()
            case .localSeed:
                let secretKeyHex = try deriveLocalSecretKeyFromWalletSeed(loadKeychainString: loadKeychainString)
                try persistKeychainString(.pubkySecretKey, secretKeyHex)
                try? deleteKeychainValue(.paykitSession)
                _ = try await signInWithSecretKey(secretKeyHex)
            }
        } catch {
            await endSessionMutation()
            throw error
        }
        await endSessionMutation()
    }

    private nonisolated static func initializePersistedSession() async throws -> SessionInitializationResult {
        try await PaykitSdkService.shared.restorePersistedSession()
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

        guard let secretKeyHex = activeSecretKeyHex(loadKeychainString: loadKeychainString) else {
            Logger.warn("Cannot refresh pubky session without a secret key", context: "PubkyProfileManager")
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
        }
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
                // A session without a reachable secret key cannot be re-established, so keep it for a later retry.
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
            Logger.warn("Re-sign-in failed, keeping saved session for retry: \(error)", context: "PubkyProfileManager")
            return .restorationFailed
        }
    }
}
