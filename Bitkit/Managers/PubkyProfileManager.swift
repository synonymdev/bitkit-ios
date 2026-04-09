import Foundation
import SwiftUI

enum PubkyAuthState: Equatable {
    case idle
    case authenticating
    case completingAuthentication
    case authenticated
    case error(String)
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
    @Published var authState: PubkyAuthState = .idle
    @Published var profile: PubkyProfile?
    @Published var publicKey: String?
    @Published var isLoadingProfile = false
    @Published var isInitialized = false
    @Published var initializationErrorMessage: String?
    @Published var sessionRestorationFailed = false
    @Published private(set) var cachedName: String?
    @Published private(set) var cachedImageUri: String?

    init() {
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
    }

    // MARK: - Initialization & Session Restoration

    private enum InitResult: Sendable {
        case noSession
        case restored(publicKey: String)
        case restorationFailed
    }

    /// Initializes Paykit and restores any persisted session in a single off-main-actor pass.
    func initialize() async {
        isInitialized = false
        initializationErrorMessage = nil
        sessionRestorationFailed = false

        let result: InitResult
        do {
            result = try await Task.detached {
                try await PubkyService.initialize()

                guard let savedSecret = try? Keychain.loadString(key: .paykitSession),
                      !savedSecret.isEmpty
                else {
                    return InitResult.noSession
                }

                // Try to import the saved session
                do {
                    let pk = try await PubkyService.importSession(secret: savedSecret)
                    return InitResult.restored(publicKey: pk)
                } catch {
                    Logger.warn("Failed to import saved session, attempting re-sign-in: \(error)", context: "PubkyProfileManager")
                }

                // Session import failed — try to recover using stored secret key
                if let secretKeyHex = try? Keychain.loadString(key: .pubkySecretKey),
                   !secretKeyHex.isEmpty
                {
                    do {
                        let newSession = try await PubkyService.signIn(secretKeyHex: secretKeyHex)
                        try Keychain.upsert(key: .paykitSession, data: Data(newSession.utf8))
                        let pk = try await PubkyService.importSession(secret: newSession)
                        Logger.info("Re-signed in and restored session for \(pk)", context: "PubkyProfileManager")
                        return InitResult.restored(publicKey: pk)
                    } catch {
                        // Both import and re-sign-in failed — session is invalid
                        Logger.error("Re-sign-in failed, clearing session: \(error)", context: "PubkyProfileManager")
                        try? Keychain.delete(key: .paykitSession)
                        return InitResult.restorationFailed
                    }
                }

                // No secret key available (Ring-managed) — keep session for next attempt
                // Could be a transient network issue; user gets a toast to reconnect if needed
                Logger.warn("No secret key to recover session", context: "PubkyProfileManager")
                return InitResult.restorationFailed
            }.value
        } catch {
            Logger.error("Failed to initialize paykit: \(error)", context: "PubkyProfileManager")
            authState = .idle
            initializationErrorMessage = error.localizedDescription
            return
        }

        switch result {
        case .noSession:
            Logger.debug("No saved paykit session found", context: "PubkyProfileManager")
        case let .restored(pk):
            publicKey = pk
            authState = .authenticated
            Logger.info("Paykit session restored for \(pk)", context: "PubkyProfileManager")
            Task { await loadProfile() }
        case .restorationFailed:
            authState = .idle
            sessionRestorationFailed = true
            clearCachedProfileMetadata()
        }

        isInitialized = true
    }

    // MARK: - Key Derivation & Identity Creation

    /// Derive the Pubky keypair from the wallet's BIP39 seed.
    /// Returns (publicKeyZ32, secretKeyHex).
    func deriveKeys() async throws -> (String, String) {
        return try await Task.detached {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else {
                throw PubkyServiceError.authFailed("Mnemonic not found")
            }
            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0))

            let seed = try PubkyService.mnemonicToSeed(mnemonic: mnemonic, passphrase: passphrase)
            let secretKeyHex = try PubkyService.derivePubkySecretKey(seed: seed)
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
        guard let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else {
            // If no session yet (creating identity), use secret key to upload
            guard let secretKeyHex = try? Keychain.loadString(key: .pubkySecretKey),
                  !secretKeyHex.isEmpty
            else {
                throw PubkyServiceError.sessionNotActive
            }

            let rawKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
            let publicKey = rawKey.hasPrefix("pubky") ? rawKey : "pubky\(rawKey)"
            return try await uploadAvatar(image: image, secretKeyHex: secretKeyHex, publicKey: publicKey)
        }

        guard let publicKey, !publicKey.isEmpty else {
            throw PubkyServiceError.sessionNotActive
        }

        return try await uploadAvatar(image: image, sessionSecret: sessionSecret, publicKey: publicKey)
    }

    /// Strip the `pubky` prefix from a public key for use in `pubky://` URIs.
    private nonisolated static func stripPubkyPrefix(_ key: String) -> String {
        key.hasPrefix("pubky") ? String(key.dropFirst(5)) : key
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

    private func avatarBlobPath() -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        switch Env.network {
        case .bitcoin:
            return "/pub/bitkit.to/blobs/\(timestamp).jpg"
        default:
            return "/pub/staging.bitkit.to/blobs/\(timestamp).jpg"
        }
    }

    private func uploadAvatar(image: UIImage, sessionSecret: String, publicKey: String) async throws -> String {
        let imageData = try compressAvatar(image)
        let blobPath = avatarBlobPath()
        let blobUri = "pubky://\(Self.stripPubkyPrefix(publicKey))\(blobPath)"

        try await PubkyService.sessionPut(sessionSecret: sessionSecret, path: blobPath, content: imageData)
        return blobUri
    }

    private func uploadAvatar(image: UIImage, secretKeyHex: String, publicKey: String) async throws -> String {
        let imageData = try compressAvatar(image)
        let blobPath = avatarBlobPath()
        let blobUri = "pubky://\(Self.stripPubkyPrefix(publicKey))\(blobPath)"

        try await PubkyService.putWithSecretKey(secretKeyHex: secretKeyHex, path: blobPath, content: imageData)
        return blobUri
    }

    /// Create a new Pubky identity: fetch signup code from Homegate, signup on homeserver,
    /// persist keys + session, upload avatar, write profile. Falls back to signIn if already registered.
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

        // Sign up on homeserver via Homegate
        let sessionSecret = try await Task.detached {
            // 1. Get signup code from Homegate
            let homegate = try await Self.fetchHomegateSignupCode()

            // 2. Sign up — if already registered, fall back to signIn
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

        var avatarUri: String?
        if let avatarImage {
            avatarUri = try await uploadAvatar(image: avatarImage, sessionSecret: sessionSecret, publicKey: publicKeyZ32)
        }
        let resolvedImageUrl = Self.resolvedImageUrl(newImageUrl: avatarUri, existingImageUrl: existingImageUrl)

        try await writeProfile(
            sessionSecret: sessionSecret,
            name: name,
            bio: bio,
            imageUrl: resolvedImageUrl,
            links: links,
            tags: tags
        )

        do {
            try Keychain.upsert(key: .pubkySecretKey, data: Data(secretKeyHex.utf8))
            try Keychain.upsert(key: .paykitSession, data: Data(sessionSecret.utf8))
            _ = try await PubkyService.importSession(secret: sessionSecret)
        } catch {
            try? Keychain.delete(key: .pubkySecretKey)
            try? Keychain.delete(key: .paykitSession)
            await PubkyService.forceSignOut()
            throw error
        }

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

        Logger.info("Pubky identity created for \(publicKeyZ32)", context: "PubkyProfileManager")
    }

    /// Update profile data on the homeserver (for edit mode).
    func saveProfile(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String] = [],
        newImageUrl: String? = nil
    ) async throws {
        guard let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else {
            throw PubkyServiceError.sessionNotActive
        }

        let resolvedImageUrl = Self.resolvedImageUrl(newImageUrl: newImageUrl, existingImageUrl: profile?.imageUrl)

        try await writeProfile(
            sessionSecret: sessionSecret,
            name: name,
            bio: bio,
            imageUrl: resolvedImageUrl,
            links: links,
            tags: tags
        )

        // Update profile locally from the data we just wrote
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

    /// Serialize profile JSON and PUT to homeserver.
    private func writeProfile(
        sessionSecret: String,
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

        let jsonData = try profileData.encoded()
        let path = Self.profilePath

        try await Task.detached {
            try await PubkyService.sessionPut(
                sessionSecret: sessionSecret,
                path: path,
                content: jsonData
            )
        }.value
    }

    private nonisolated static var profilePath: String {
        switch Env.network {
        case .bitcoin:
            return "/pub/bitkit.to/profile.json"
        default:
            return "/pub/staging.bitkit.to/profile.json"
        }
    }

    static func isRingAvailable() -> Bool {
        guard let url = URL(string: "pubkyauth://check") else {
            return false
        }

        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: - Auth Flow (Ring)

    func cancelAuthentication() async {
        do {
            try await Task.detached {
                try await PubkyService.cancelAuth()
            }.value
            authState = .idle
        } catch {
            authState = .idle
            Logger.warn("Cancel auth failed: \(error)", context: "PubkyProfileManager")
        }
    }

    func startAuthentication() async throws {
        authState = .authenticating

        guard Self.isRingAvailable() else {
            authState = .idle
            throw PubkyServiceError.ringNotInstalled
        }

        let authUrl: String
        do {
            authUrl = try await Task.detached {
                try await PubkyService.startAuth()
            }.value
        } catch {
            authState = .idle
            throw error
        }

        guard let url = URL(string: authUrl) else {
            await cancelPendingAuthSetup()
            authState = .idle
            throw PubkyServiceError.invalidAuthUrl
        }

        let canOpen = UIApplication.shared.canOpenURL(url)
        guard canOpen else {
            await cancelPendingAuthSetup()
            authState = .idle
            throw PubkyServiceError.ringNotInstalled
        }

        let didOpen = await UIApplication.shared.open(url)
        guard didOpen else {
            await cancelPendingAuthSetup()
            authState = .idle
            throw PubkyServiceError.authFailed("Failed to open Pubky Ring")
        }
    }

    /// Long-polls the relay, persists + imports the session, and loads the profile in a single off-main-actor pass.
    @discardableResult
    func completeAuthentication() async throws -> String {
        do {
            let pk = try await Task.detached {
                let sessionSecret = try await PubkyService.completeAuth()
                let pk = try await PubkyService.importSession(secret: sessionSecret)

                guard let data = sessionSecret.data(using: .utf8) else {
                    await PubkyService.forceSignOut()
                    throw PubkyServiceError.authFailed("Failed to encode session secret")
                }

                do {
                    try Keychain.upsert(key: .paykitSession, data: data)
                } catch {
                    await PubkyService.forceSignOut()
                    throw error
                }

                return pk
            }.value

            publicKey = pk
            authState = .completingAuthentication
            Logger.info("Pubky auth completed for \(pk)", context: "PubkyProfileManager")
            await loadProfile()
            return pk
        } catch let serviceError as PubkyServiceError {
            authState = .idle
            throw serviceError
        } catch {
            authState = .error(error.localizedDescription)
            throw error
        }
    }

    func finalizeAuthentication() {
        guard case .completingAuthentication = authState else { return }
        authState = .authenticated
    }

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
        try await resolveRemoteProfile(
            publicKey: publicKey,
            fetchBitkitProfile: fetchBitkitProfile,
            fetchPubkyProfile: fetchPubkyProfile
        )
    }

    nonisolated static func resolveRemoteProfile(
        publicKey: String,
        fetchBitkitProfile: @escaping @Sendable (String) async -> PubkyProfile?,
        fetchPubkyProfile: @escaping @Sendable (String) async throws -> PubkyProfile
    ) async throws -> PubkyProfile {
        if let bitkitProfile = await fetchBitkitProfile(publicKey) {
            return bitkitProfile
        }

        return try await fetchPubkyProfile(publicKey)
    }

    /// Read the user's bitkit profile.json which contains the complete profile data we wrote.
    private nonisolated static func fetchBitkitProfile(publicKey: String) async -> PubkyProfile? {
        let strippedKey = stripPubkyPrefix(publicKey)
        let uri = "pubky://\(strippedKey)\(profilePath)"

        do {
            let jsonString = try await PubkyService.fetchFileString(uri: uri)
            let profileData = try PubkyProfileData.decode(from: jsonString)
            Logger.debug("Fetched bitkit profile.json for \(publicKey)", context: "PubkyProfileManager")
            return profileData.toProfile(publicKey: publicKey)
        } catch {
            Logger.debug("Could not fetch bitkit profile.json: \(error)", context: "PubkyProfileManager")
            return nil
        }
    }

    private nonisolated static func fetchPubkyProfile(publicKey: String) async throws -> PubkyProfile {
        let profileDto = try await PubkyService.getProfile(publicKey: publicKey)
        Logger.debug(
            "Profile loaded from pubky FFI — name: \(profileDto.name), image: \(profileDto.image ?? "nil")",
            context: "PubkyProfileManager"
        )
        return PubkyProfile(publicKey: publicKey, ffiProfile: profileDto)
    }

    // MARK: - Sign Out

    func signOut() async {
        let nameKey = Self.cachedNameKey
        let imageKey = Self.cachedImageUriKey
        await Task.detached {
            do {
                try await PubkyService.signOut()
            } catch {
                Logger.warn("Server sign out failed, forcing local sign out: \(error)", context: "PubkyProfileManager")
                await PubkyService.forceSignOut()
            }
            try? Keychain.delete(key: .paykitSession)
            try? Keychain.delete(key: .pubkySecretKey)
            PubkyImageCache.shared.clear()
            UserDefaults.standard.removeObject(forKey: nameKey)
            UserDefaults.standard.removeObject(forKey: imageKey)
        }.value

        cachedName = nil
        cachedImageUri = nil
        publicKey = nil
        profile = nil
        authState = .idle
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

    // MARK: - Helpers

    var isAuthenticated: Bool {
        authState == .authenticated
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
}
