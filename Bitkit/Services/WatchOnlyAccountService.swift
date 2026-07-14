import Combine
import CryptoKit
import Foundation
import LDKNode

enum WatchOnlyAccountSetupState: String, Codable {
    case pendingDelivery
    case active
}

struct WatchOnlyAccountRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let walletIndex: Int
    let accountIndex: UInt32
    let addressType: String
    let xpub: String
    let requestFingerprint: String
    let createdAt: UInt64
    var name: String
    var isTrackingEnabled: Bool
    var setupState: WatchOnlyAccountSetupState

    var derivationPath: String {
        let coinType = Env.network == .bitcoin ? "0" : "1"
        return "m/84'/\(coinType)'/\(accountIndex)'"
    }
}

enum WatchOnlyAccountError: LocalizedError, Equatable {
    case invalidAccountName
    case invalidAuthRequest
    case invalidExtendedPublicKey
    case companionTransportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAccountName:
            t("pubky_auth__watch_only_account_name_error")
        case .invalidAuthRequest:
            t("pubky_auth__watch_only_auth_request_error")
        case .invalidExtendedPublicKey:
            t("pubky_auth__watch_only_account_xpub_error")
        case .companionTransportUnavailable:
            t("pubky_auth__watch_only_transport_unavailable")
        }
    }
}

protocol WatchOnlyAccountClaimTransport: Sendable {
    func deliver(payload: Data, authUrl: String) async throws
}

struct UnavailableWatchOnlyAccountClaimTransport: WatchOnlyAccountClaimTransport {
    func deliver(payload _: Data, authUrl _: String) async throws {
        throw WatchOnlyAccountError.companionTransportUnavailable
    }
}

protocol WatchOnlyAccountNodeHandling: AnyObject {
    var currentWalletIndex: Int { get }
    func createAndTrackWatchOnlyAccount(accountIndex: UInt32, addressType: LDKNode.AddressType) async throws -> String
}

extension LightningService: WatchOnlyAccountNodeHandling {}

enum WatchOnlyAccountStore {
    static let walletBackupDataChangedPublisher = walletBackupDataChangedSubject.eraseToAnyPublisher()

    private static let defaultsKey = "watchOnlyAccountsV1"
    private static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    static func load(defaults: UserDefaults = .standard) -> [WatchOnlyAccountRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([WatchOnlyAccountRecord].self, from: data)
        else { return [] }

        return records.sorted { $0.accountIndex < $1.accountIndex }
    }

    static func save(_ records: [WatchOnlyAccountRecord], defaults: UserDefaults = .standard) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: defaultsKey)
        walletBackupDataChangedSubject.send()
    }

    static func restore(_ records: [WatchOnlyAccountRecord]?, defaults: UserDefaults = .standard) throws {
        try save(records ?? [], defaults: defaults)
    }
}

@Observable
@MainActor
final class WatchOnlyAccountManager {
    static let shared = WatchOnlyAccountManager()

    private(set) var accounts: [WatchOnlyAccountRecord]

    private let defaults: UserDefaults
    private let node: WatchOnlyAccountNodeHandling
    private let transport: WatchOnlyAccountClaimTransport

    init(
        defaults: UserDefaults = .standard,
        node: WatchOnlyAccountNodeHandling = LightningService.shared,
        transport: WatchOnlyAccountClaimTransport = UnavailableWatchOnlyAccountClaimTransport()
    ) {
        self.defaults = defaults
        self.node = node
        self.transport = transport
        accounts = WatchOnlyAccountStore.load(defaults: defaults)
    }

    func accounts(for walletIndex: Int) -> [WatchOnlyAccountRecord] {
        accounts.filter { $0.walletIndex == walletIndex }
    }

    func prepareSignedClaim(authUrl: String, name: String, secretKeyHex: String) async throws -> (WatchOnlyAccountRecord, Data) {
        let normalizedName = try Self.normalizedName(name)
        let fingerprint = Self.requestFingerprint(authUrl)

        if let existing = accounts.first(where: {
            $0.walletIndex == node.currentWalletIndex && $0.requestFingerprint == fingerprint
        }) {
            if existing.name != normalizedName {
                try rename(id: existing.id, name: normalizedName)
            }
            let refreshed = accounts.first(where: { $0.id == existing.id }) ?? existing
            let payload = try WatchOnlyAccountClaimCodec.encode(record: refreshed, authUrl: authUrl, secretKeyHex: secretKeyHex)
            return (refreshed, payload)
        }

        let walletAccounts = accounts(for: node.currentWalletIndex)
        let highestAccountIndex = walletAccounts.map(\.accountIndex).max() ?? 0
        guard highestAccountIndex < UInt32(Int32.max) else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }
        let (accountIndex, overflow) = highestAccountIndex.addingReportingOverflow(1)
        guard !overflow else { throw WatchOnlyAccountError.invalidExtendedPublicKey }
        let addressType = LDKNode.AddressType.nativeSegwit
        let xpub = try await node.createAndTrackWatchOnlyAccount(accountIndex: accountIndex, addressType: addressType)
        let record = WatchOnlyAccountRecord(
            id: UUID(),
            walletIndex: node.currentWalletIndex,
            accountIndex: accountIndex,
            addressType: addressType.stringValue,
            xpub: xpub,
            requestFingerprint: fingerprint,
            createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
            name: normalizedName,
            isTrackingEnabled: true,
            setupState: .pendingDelivery
        )

        accounts.append(record)
        try persist()
        return try (record, WatchOnlyAccountClaimCodec.encode(record: record, authUrl: authUrl, secretKeyHex: secretKeyHex))
    }

    func deliver(payload: Data, authUrl: String) async throws {
        try await transport.deliver(payload: payload, authUrl: authUrl)
    }

    func markSetupActive(id: UUID) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].setupState = .active
        try persist()
    }

    func rename(id: UUID, name: String) throws {
        let normalizedName = try Self.normalizedName(name)
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = normalizedName
        try persist()
    }

    func setTrackingEnabled(id: UUID, enabled: Bool) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].isTrackingEnabled = enabled
        try persist()
    }

    func reload() {
        accounts = WatchOnlyAccountStore.load(defaults: defaults)
    }

    private func persist() throws {
        accounts.sort { $0.accountIndex < $1.accountIndex }
        try WatchOnlyAccountStore.save(accounts, defaults: defaults)
    }

    private static func normalizedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 64 else {
            throw WatchOnlyAccountError.invalidAccountName
        }
        return normalized
    }

    private static func requestFingerprint(_ authUrl: String) -> String {
        Data(SHA256.hash(data: Data(authUrl.utf8))).base64EncodedString()
    }
}

enum WatchOnlyAccountClaimCodec {
    static let version: UInt8 = 1
    static let nativeSegwitAddressType: UInt8 = 0
    static let serializedXpubLength = 78
    static let payloadLength = 1 + 4 + 1 + serializedXpubLength + 64

    private static let signatureDomain = Data("x-bitkit-claim|watch-only-account-v1|".utf8)

    static func encode(record: WatchOnlyAccountRecord, authUrl: String, secretKeyHex: String) throws -> Data {
        guard record.addressType == LDKNode.AddressType.nativeSegwit.stringValue else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }

        let rawXpub = try serializedXpub(record.xpub)
        var claim = Data([version])
        claim.append(contentsOf: withUnsafeBytes(of: record.accountIndex.bigEndian, Array.init))
        claim.append(nativeSegwitAddressType)
        claim.append(rawXpub)

        let privateKeyBytes = secretKeyHex.trimmingCharacters(in: .whitespacesAndNewlines).hexaData
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        let requestSecretHash = try requestSecretHash(authUrl: authUrl)
        let signature = try privateKey.signature(for: signatureDomain + requestSecretHash + claim)
        claim.append(signature)
        return claim
    }

    static func requestSecretHash(authUrl: String) throws -> Data {
        guard let components = URLComponents(string: authUrl) else {
            throw WatchOnlyAccountError.invalidAuthRequest
        }
        let secrets = components.queryItems?.filter { $0.name == "secret" }.compactMap(\.value) ?? []
        guard secrets.count == 1, let secret = secrets.first, !secret.isEmpty else {
            throw WatchOnlyAccountError.invalidAuthRequest
        }
        return Data(SHA256.hash(data: Data(secret.utf8)))
    }

    static func serializedXpub(_ xpub: String) throws -> Data {
        let decoded = try Base58Check.decode(xpub)
        guard decoded.count == serializedXpubLength else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }
        return decoded
    }
}

private enum Base58Check {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let alphabetIndexes = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty else { throw WatchOnlyAccountError.invalidExtendedPublicKey }

        var bytes = [UInt8](repeating: 0, count: 1)
        for character in value {
            guard let digit = alphabetIndexes[character] else {
                throw WatchOnlyAccountError.invalidExtendedPublicKey
            }

            var carry = digit
            for index in bytes.indices.reversed() {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }

        let leadingZeros = value.prefix { $0 == "1" }.count
        bytes = Array(repeating: 0, count: leadingZeros) + Array(bytes.drop { $0 == 0 })
        guard bytes.count > 4 else { throw WatchOnlyAccountError.invalidExtendedPublicKey }

        let payload = Data(bytes.dropLast(4))
        let checksum = Data(bytes.suffix(4))
        let firstHash = SHA256.hash(data: payload)
        let expectedChecksum = Data(SHA256.hash(data: Data(firstHash))).prefix(4)
        guard checksum == expectedChecksum else {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }
        return payload
    }
}
