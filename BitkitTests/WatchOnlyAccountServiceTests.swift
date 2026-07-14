@testable import Bitkit
import CryptoKit
import LDKNode
import XCTest

final class WatchOnlyAccountServiceTests: XCTestCase {
    func testSignedClaimContainsAccountMetadataAndVerifiableSignature() throws {
        let rawXpub = Data((0 ..< WatchOnlyAccountClaimCodec.serializedXpubLength).map(UInt8.init))
        let privateKeyBytes = Data(repeating: 7, count: 32)
        let record = makeRecord(accountIndex: 42, xpub: base58CheckEncode(rawXpub))

        let authUrl = "pubkyauth:///?secret=request-secret"
        let payload = try WatchOnlyAccountClaimCodec.encode(record: record, authUrl: authUrl, secretKeyHex: privateKeyBytes.hex)

        XCTAssertEqual(payload.count, WatchOnlyAccountClaimCodec.payloadLength)
        XCTAssertEqual(payload[0], WatchOnlyAccountClaimCodec.version)
        XCTAssertEqual(payload[5], WatchOnlyAccountClaimCodec.nativeSegwitAddressType)
        XCTAssertEqual(payload.subdata(in: 6 ..< 84), rawXpub)

        let accountIndex = payload[1 ..< 5].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(accountIndex, 42)

        let unsignedClaim = payload.prefix(84)
        let signature = payload.suffix(64)
        let requestSecretHash = try WatchOnlyAccountClaimCodec.requestSecretHash(authUrl: authUrl)
        let signable = Data("x-bitkit-claim|watch-only-account-v1|".utf8) + requestSecretHash + unsignedClaim
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes).publicKey
        XCTAssertTrue(publicKey.isValidSignature(signature, for: signable))
    }

    func testRequestSecretHashPercentDecodesWithoutTreatingPlusAsSpace() throws {
        let hash = try WatchOnlyAccountClaimCodec.requestSecretHash(
            authUrl: "pubkyauth://signin?secret=one%2Ftwo+three"
        )

        XCTAssertEqual(hash, Data(SHA256.hash(data: Data("one/two+three".utf8))))
    }

    @MainActor
    func testEachRequestGetsANewAccountAndRetryReusesPendingAccount() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)
        let secret = Data(repeating: 9, count: 32).hex

        let first = try await manager.prepareSignedClaim(authUrl: "pubkyauth:///?secret=one", name: "Store one", secretKeyHex: secret)
        let retry = try await manager.prepareSignedClaim(authUrl: "pubkyauth:///?secret=one", name: "Changed", secretKeyHex: secret)
        let second = try await manager.prepareSignedClaim(authUrl: "pubkyauth:///?secret=two", name: "Store two", secretKeyHex: secret)

        XCTAssertEqual(first.0.accountIndex, 1)
        XCTAssertEqual(retry.0.id, first.0.id)
        XCTAssertEqual(second.0.accountIndex, 2)
        XCTAssertEqual(node.createdAccountIndexes, [1, 2])
        XCTAssertEqual(WatchOnlyAccountStore.load(defaults: defaults).count, 2)
    }

    @MainActor
    func testRenameTrackingAndActiveStatePersist() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = WatchOnlyAccountManager(defaults: defaults, node: FakeWatchOnlyAccountNode())
        let prepared = try await manager.prepareSignedClaim(
            authUrl: "pubkyauth:///?secret=state",
            name: "Original",
            secretKeyHex: Data(repeating: 3, count: 32).hex
        )

        try manager.rename(id: prepared.0.id, name: "Creator shop")
        try manager.setTrackingEnabled(id: prepared.0.id, enabled: false)
        try manager.markSetupActive(id: prepared.0.id)

        let stored = try XCTUnwrap(WatchOnlyAccountStore.load(defaults: defaults).first)
        XCTAssertEqual(stored.name, "Creator shop")
        XCTAssertFalse(stored.isTrackingEnabled)
        XCTAssertEqual(stored.setupState, .active)
    }

    private func makeRecord(accountIndex: UInt32, xpub: String) -> WatchOnlyAccountRecord {
        WatchOnlyAccountRecord(
            id: UUID(),
            walletIndex: 0,
            accountIndex: accountIndex,
            addressType: LDKNode.AddressType.nativeSegwit.stringValue,
            xpub: xpub,
            requestFingerprint: "request",
            createdAt: 1000,
            name: "Test",
            isTrackingEnabled: true,
            setupState: .pendingDelivery
        )
    }

    private func base58CheckEncode(_ payload: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        let firstHash = SHA256.hash(data: payload)
        let checksum = Data(SHA256.hash(data: Data(firstHash))).prefix(4)
        let source = [UInt8](payload + checksum)
        var digits = [Int](repeating: 0, count: 1)

        for byte in source {
            var carry = Int(byte)
            for index in digits.indices.reversed() {
                carry += digits[index] << 8
                digits[index] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.insert(carry % 58, at: 0)
                carry /= 58
            }
        }

        let leadingZeros = source.prefix { $0 == 0 }.count
        return String(repeating: "1", count: leadingZeros) + String(digits.drop { $0 == 0 }.map { alphabet[$0] })
    }
}

private final class FakeWatchOnlyAccountNode: WatchOnlyAccountNodeHandling {
    var currentWalletIndex = 0
    private(set) var createdAccountIndexes: [UInt32] = []

    func createAndTrackWatchOnlyAccount(accountIndex: UInt32, addressType _: LDKNode.AddressType) async throws -> String {
        createdAccountIndexes.append(accountIndex)
        let rawXpub = Data((0 ..< WatchOnlyAccountClaimCodec.serializedXpubLength).map { UInt8(($0 + Int(accountIndex)) % 256) })
        return base58CheckEncode(rawXpub)
    }

    private func base58CheckEncode(_ payload: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        let firstHash = SHA256.hash(data: payload)
        let checksum = Data(SHA256.hash(data: Data(firstHash))).prefix(4)
        let source = [UInt8](payload + checksum)
        var digits = [Int](repeating: 0, count: 1)

        for byte in source {
            var carry = Int(byte)
            for index in digits.indices.reversed() {
                carry += digits[index] << 8
                digits[index] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.insert(carry % 58, at: 0)
                carry /= 58
            }
        }

        let leadingZeros = source.prefix { $0 == 0 }.count
        return String(repeating: "1", count: leadingZeros) + String(digits.drop { $0 == 0 }.map { alphabet[$0] })
    }
}
