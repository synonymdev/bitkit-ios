import Foundation

enum SharedPubkyIdentitySource: String, Codable, Equatable {
    case ring = "app.pubkyring"
    case bitkit = "to.bitkit"
}

enum SharedPubkyKeyFormat {
    private static let prefix = "pubky"
    private static let bareKeyLength = 52
    private static let allowedCharacters = Set("ybndrfg8ejkmcpqxot1uwisza345h769")
    private static let secretKeyLength = 64
    private static let secretKeyCharacters = Set("0123456789abcdef")

    static func normalizedBare(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
        guard bare.count == bareKeyLength,
              bare.allSatisfy({ allowedCharacters.contains($0) })
        else {
            return nil
        }
        return bare
    }

    static func isCanonicalSecretKey(_ value: String) -> Bool {
        value.count == secretKeyLength &&
            value.allSatisfy { secretKeyCharacters.contains($0) }
    }

    static func prefixed(_ bareValue: String) -> String? {
        guard let bare = normalizedBare(bareValue), bare == bareValue else {
            return nil
        }
        return "\(prefix)\(bare)"
    }
}

/// App-private pointer to an identity whose canonical secret remains owned by another app.
struct SharedPubkyIdentityRefV1: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let sourceApp: SharedPubkyIdentitySource
    let pubky: String

    init(sourceApp: SharedPubkyIdentitySource, pubky: String) throws {
        guard let normalizedPubky = SharedPubkyKeyFormat.normalizedBare(pubky) else {
            throw SharedPubkyIdentityError.invalidPublicKey
        }

        version = Self.currentVersion
        self.sourceApp = sourceApp
        self.pubky = normalizedPubky
    }
}

/// Payload stored in the shared Keychain access group by the app that owns the identity.
struct SharedPubkyIdentityRecordV1: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let sourceApp: SharedPubkyIdentitySource
    let pubky: String
    let secretKey: String

    init(sourceApp: SharedPubkyIdentitySource, pubky: String, secretKey: String) {
        version = Self.currentVersion
        self.sourceApp = sourceApp
        self.pubky = pubky
        self.secretKey = secretKey
    }
}

struct SharedPubkyIdentityOption: Identifiable {
    let reference: SharedPubkyIdentityRefV1
    let profile: PubkyProfile

    var id: String {
        reference.pubky
    }
}

enum SharedPubkyIdentityError: LocalizedError, Equatable {
    case unavailable
    case missingEntitlement
    case invalidRecord
    case invalidPublicKey
    case secretDoesNotMatchPublicKey
    case sourceUnavailable
    case sourceIdentityMissing
    case provenanceConflict

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Shared Pubky identities are unavailable"
        case .missingEntitlement:
            return "Shared Pubky Keychain access is not configured"
        case .invalidRecord:
            return "The shared Pubky identity is invalid"
        case .invalidPublicKey:
            return "The shared Pubky public key is invalid"
        case .secretDoesNotMatchPublicKey:
            return "The shared Pubky secret does not match its public key"
        case .sourceUnavailable:
            return "Pubky Ring is unavailable"
        case .sourceIdentityMissing:
            return "The selected Pubky Ring identity is no longer available"
        case .provenanceConflict:
            return "Conflicting Pubky identity sources require recovery"
        }
    }
}
