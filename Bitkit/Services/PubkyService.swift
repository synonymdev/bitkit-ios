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
    static let requiredCapabilities = "/pub/paykit.app/v0/:rw,/pub/pubky.app/profile.json:rw,/pub/pubky.app/follows/:rw"

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
            try await startPubkyAuth(caps: requiredCapabilities)
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

    // MARK: - File Fetching

    /// Fetch raw bytes from a `pubky://` URI via PKDNS resolution.
    static func fetchFile(uri: String) async throws -> Data {
        try await ServiceQueue.background(.core) {
            let bytes = try await fetchPubkyFile(uri: uri)
            return Data(bytes)
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
