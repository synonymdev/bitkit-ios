import BitkitCore
import Foundation
import Paykit

enum PubkyServiceError: LocalizedError {
    case invalidAuthUrl
    case ringNotInstalled
    case sessionNotActive
    case authFailed(String)
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidAuthUrl:
            return "Failed to generate auth URL"
        case .ringNotInstalled:
            return "Pubky Ring is not installed"
        case .sessionNotActive:
            return "No active Pubky session"
        case let .authFailed(reason):
            return "Authentication failed: \(reason)"
        case .profileNotFound:
            return "Profile not found"
        }
    }
}

/// Service layer wrapping BitkitCore (auth) and PaykitFFI (profile/contacts/payments).
enum PubkyService {
    static func initialize() async throws {
        try await ServiceQueue.background(.core) {
            try await paykitInitialize()
        }
    }

    // MARK: - Session Management

    /// Import a session secret into paykit and return the public key.
    static func importSession(secret: String) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await paykitImportSession(sessionSecret: secret)
        }
    }

    static func exportSession() async throws -> String {
        try await ServiceQueue.background(.core) {
            try await paykitExportSession()
        }
    }

    static func isAuthenticated() async -> Bool {
        await (try? ServiceQueue.background(.core) {
            await paykitIsAuthenticated()
        }) ?? false
    }

    static func currentPublicKey() async -> String? {
        try? await ServiceQueue.background(.core) {
            await paykitGetCurrentPublicKey()
        }
    }

    // MARK: - Auth Flow (BitkitCore)

    /// Step 1: Generate the pubkyauth:// URL to open in Pubky Ring.
    static func startAuth() async throws -> String {
        try await ServiceQueue.background(.core) {
            try await startPubkyAuth(caps: Env.pubkyCapabilities)
        }
    }

    /// Step 2: Long-poll until Ring approves. Returns the raw session secret.
    static func completeAuth() async throws -> String {
        try await ServiceQueue.background(.core) {
            try await completePubkyAuth()
        }
    }

    /// Cancel an in-progress auth relay poll started by `startAuth`.
    static func cancelAuth() async throws {
        try await ServiceQueue.background(.core) {
            try await cancelPubkyAuth()
        }
    }

    // MARK: - Auth Approval (Bitkit as authenticator)

    /// Parse a pubkyauth:// URL to extract details for UI display.
    static func parseAuthUrl(_ authUrl: String) throws -> BitkitCore.PubkyAuthDetails {
        try parsePubkyAuthUrl(authUrl: authUrl)
    }

    /// Approve a pubkyauth:// request using the local secret key.
    static func approveAuth(authUrl: String, secretKeyHex: String) async throws {
        try await ServiceQueue.background(.core) {
            try await approvePubkyAuth(authUrl: authUrl, secretKeyHex: secretKeyHex)
        }
    }

    // MARK: - Key Derivation

    /// Convert a BIP39 mnemonic to a seed.
    static func mnemonicToSeed(mnemonic: String, passphrase: String? = nil) throws -> Data {
        try BitkitCore.mnemonicToSeed(mnemonicPhrase: mnemonic, passphrase: passphrase)
    }

    /// Derive an Ed25519 secret key from a BIP39 seed. Returns hex-encoded 32-byte key.
    static func derivePubkySecretKey(seed: Data) throws -> String {
        try BitkitCore.derivePubkySecretKey(seed: seed)
    }

    /// Derive the z32-encoded public key from a hex-encoded secret key.
    static func pubkyPublicKeyFromSecret(secretKeyHex: String) throws -> String {
        try BitkitCore.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
    }

    // MARK: - Homeserver Auth

    /// Sign up on a homeserver. Returns session secret for persistence.
    static func signUp(secretKeyHex: String, homeserverZ32: String, signupCode: String? = nil) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await pubkySignUp(secretKeyHex: secretKeyHex, homeserverPublicKeyZ32: homeserverZ32, signupCode: signupCode)
        }
    }

    /// Sign in with an existing secret key. Returns new session secret.
    static func signIn(secretKeyHex: String) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await pubkySignIn(secretKeyHex: secretKeyHex)
        }
    }

    // MARK: - Authenticated Storage

    /// Write content to a path on the user's homeserver.
    static func sessionPut(sessionSecret: String, path: String, content: Data) async throws {
        try await ServiceQueue.background(.core) {
            try await pubkySessionPut(sessionSecret: sessionSecret, path: path, content: content)
        }
    }

    /// Delete a resource at path on the user's homeserver.
    static func sessionDelete(sessionSecret: String, path: String) async throws {
        try await ServiceQueue.background(.core) {
            try await pubkySessionDelete(sessionSecret: sessionSecret, path: path)
        }
    }

    /// List resources in a directory on the user's homeserver.
    static func sessionList(sessionSecret: String, dirPath: String) async throws -> [String] {
        try await ServiceQueue.background(.core) {
            try await pubkySessionList(sessionSecret: sessionSecret, dirPath: dirPath)
        }
    }

    /// Sign in with secret key and write content in one shot.
    static func putWithSecretKey(secretKeyHex: String, path: String, content: Data) async throws {
        try await ServiceQueue.background(.core) {
            try await pubkyPutWithSecretKey(secretKeyHex: secretKeyHex, path: path, content: content)
        }
    }

    // MARK: - File Fetching

    /// Fetch raw bytes from a `pubky://` URI via PKDNS resolution.
    static func fetchFile(uri: String) async throws -> Data {
        try await ServiceQueue.background(.core) {
            try await fetchPubkyFile(uri: uri)
        }
    }

    /// Fetch a public resource from a `pubky://` URI and return as a UTF-8 string.
    static func fetchFileString(uri: String) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await fetchPubkyFileString(uri: uri)
        }
    }

    // MARK: - Profile

    static func getProfile(publicKey: String) async throws -> BitkitCore.PubkyProfile {
        try await ServiceQueue.background(.core) {
            try await fetchPubkyProfile(publicKey: publicKey)
        }
    }

    // MARK: - Contacts

    static func getContacts(publicKey: String) async throws -> [String] {
        try await ServiceQueue.background(.core) {
            try await fetchPubkyContacts(publicKey: publicKey)
        }
    }

    // MARK: - Payments

    static func getPaymentList(publicKey: String) async throws -> [FfiPaymentEntry] {
        try await ServiceQueue.background(.core) {
            try await paykitGetPaymentList(publicKey: publicKey)
        }
    }

    static func getPaymentEndpoint(publicKey: String, methodId: String) async throws -> String? {
        try await ServiceQueue.background(.core) {
            try await paykitGetPaymentEndpoint(publicKey: publicKey, methodId: methodId)
        }
    }

    static func setPaymentEndpoint(methodId: String, endpointData: String) async throws {
        try await ServiceQueue.background(.core) {
            try await paykitSetPaymentEndpoint(methodId: methodId, endpointData: endpointData)
        }
    }

    static func removePaymentEndpoint(methodId: String) async throws {
        try await ServiceQueue.background(.core) {
            try await paykitRemovePaymentEndpoint(methodId: methodId)
        }
    }

    // MARK: - Sign Out

    static func signOut() async throws {
        try await ServiceQueue.background(.core) {
            try await paykitSignOut()
        }
    }

    static func forceSignOut() async {
        _ = try? await ServiceQueue.background(.core) {
            await paykitForceSignOut()
        }
    }
}
