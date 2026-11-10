import BitkitCore
import Foundation

/// What this install registers with the wake gateway: made once, reused across launches and never backed up. The
/// notification extension reads it from the shared keychain to decrypt and acknowledge wakes.
struct WakeCredentials: Codable, Equatable {
    let installId: String
    let encryptionPublicKey: String
    let encryptionSecretKey: String
    let deviceSecret: String
    let deviceSecretSha256: String

    static func generate() throws -> WakeCredentials {
        let keyPair = try wakeGenerateKeypair()
        let secret = try wakeGenerateDeviceSecret()
        return WakeCredentials(
            installId: wakeGenerateInstallId(),
            encryptionPublicKey: keyPair.publicKeyHex,
            encryptionSecretKey: keyPair.secretKeyHex,
            deviceSecret: secret.token,
            deviceSecretSha256: secret.sha256Hex
        )
    }
}

/// Leaves the secret key and the device secret out of logs and test failures.
extension WakeCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "WakeCredentials(installId: \(installId), encryptionPublicKey: \(encryptionPublicKey))"
    }

    var debugDescription: String {
        description
    }
}

/// Everything a registration signs apart from the install's credentials and timestamp, so an unchanged registration is
/// not sent again.
struct WakeRegistrationContent: Codable, Equatable {
    let audience: String
    let environment: String
    let pushToken: String
    let encryptionPublicKey: String
    let identities: [String]
    let topics: [String]

    init(audience: String, environment: String, pushToken: String, encryptionPublicKey: String, identities: [String], topics: [String]) {
        self.audience = audience
        self.environment = environment
        self.pushToken = pushToken
        self.encryptionPublicKey = encryptionPublicKey
        self.identities = Array(Set(identities)).sorted()
        self.topics = Array(Set(topics)).sorted()
    }
}

struct WakeRegisteredDevice: Codable, Equatable {
    let gatewayUrl: String
    let content: WakeRegistrationContent
}

struct WakeRegistrationRecord: Codable, Equatable {
    /// The newest `ts` the gateway may have accepted for this install. The gateway answers 409 to an older one.
    var lastTimestamp: UInt64?
    /// What the gateway accepted last, while the install is registered.
    var device: WakeRegisteredDevice?
}

enum WakeTimestamp {
    /// How far the gateway lets `ts` stray from its clock.
    static let maxSkewSecs: UInt64 = 600

    /// `max(now, last + 1)`, so a relaunch within the same second or a clock that stepped back is not refused as stale.
    static func next(now: UInt64, last: UInt64?) -> UInt64 {
        guard let last else { return now }
        return max(now, last + 1)
    }

    /// The timestamp to sign again with after a 401 `stale_timestamp`, which carries the gateway's clock. A `last` too far
    /// ahead of that clock was never accepted, so only an earlier one has to be passed.
    static func retry(serverTime: UInt64, last: UInt64?) -> UInt64 {
        guard let last, last < serverTime + maxSkewSecs else { return serverTime }
        return max(serverTime, last + 1)
    }

    static var now: UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }
}

enum WakeStorage {
    static func loadCredentials() throws -> WakeCredentials? {
        try load(WakeCredentials.self, key: .wakeCredentials)
    }

    static func loadOrCreateCredentials() throws -> WakeCredentials {
        if let credentials = try loadCredentials() {
            return credentials
        }
        let credentials = try WakeCredentials.generate()
        try Keychain.save(key: .wakeCredentials, data: JSONEncoder().encode(credentials))
        Logger.info("Created wake credentials", context: "Wake")
        return credentials
    }

    static func loadRegistration() throws -> WakeRegistrationRecord {
        try load(WakeRegistrationRecord.self, key: .wakeRegistration) ?? WakeRegistrationRecord()
    }

    static func saveRegistration(_ record: WakeRegistrationRecord) throws {
        try Keychain.upsert(key: .wakeRegistration, data: JSONEncoder().encode(record))
    }

    private static func load<T: Decodable>(_ type: T.Type, key: KeychainEntryType) throws -> T? {
        guard let data = try Keychain.load(key: key) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}
