@testable import Bitkit
import Security
import XCTest

final class SharedPubkyKeychainTests: XCTestCase {
    private static let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private func makeSecretAndPubky() throws -> (secretKeyHex: String, pubky: String) {
        let secretKeyHex = try PubkyService.derivePubkySecretKey(mnemonic: Self.mnemonic)
        return try (secretKeyHex, SharedPubkyKeychain.derivedPubky(fromSecretKeyHex: secretKeyHex))
    }

    func testAcceptsMatchingSecret() throws {
        let (secretKeyHex, pubky) = try makeSecretAndPubky()
        XCTAssertTrue(SharedPubkyKeychain.isValidSecret(secretKeyHex, pubky: pubky))
    }

    func testRejectsShortSecret() throws {
        let (secretKeyHex, pubky) = try makeSecretAndPubky()
        XCTAssertFalse(SharedPubkyKeychain.isValidSecret(String(secretKeyHex.dropLast(2)), pubky: pubky))
    }

    func testRejectsUppercaseSecret() throws {
        let (secretKeyHex, pubky) = try makeSecretAndPubky()
        XCTAssertFalse(SharedPubkyKeychain.isValidSecret(secretKeyHex.uppercased(), pubky: pubky))
    }

    func testRejectsNonHexSecret() throws {
        let (_, pubky) = try makeSecretAndPubky()
        XCTAssertFalse(SharedPubkyKeychain.isValidSecret(String(repeating: "z", count: 64), pubky: pubky))
    }

    func testRejectsSecretForAnotherPubky() throws {
        let (_, pubky) = try makeSecretAndPubky()
        let otherSecretKeyHex = String(repeating: "01", count: 32)
        XCTAssertNotEqual(try SharedPubkyKeychain.derivedPubky(fromSecretKeyHex: otherSecretKeyHex), pubky)
        XCTAssertFalse(SharedPubkyKeychain.isValidSecret(otherSecretKeyHex, pubky: pubky))
    }

    func testReadSecretDistinguishesMissingAndUnreadableRecords() throws {
        let (secretKeyHex, pubky) = try makeSecretAndPubky()
        let cases: [(status: OSStatus, data: Data?, expected: String?, fails: Bool)] = [
            (errSecItemNotFound, nil, nil, false),
            (errSecInteractionNotAllowed, nil, nil, true),
            (errSecSuccess, nil, nil, true),
            (errSecSuccess, Data([0xFF]), nil, true),
            (errSecSuccess, Data("invalid-key".utf8), nil, true),
            (errSecSuccess, Data(secretKeyHex.utf8), secretKeyHex, false),
            (errSecSuccess, Data(String(repeating: "01", count: 32).utf8), nil, false),
        ]
        for testCase in cases {
            let read = {
                try SharedPubkyKeychain.readSecret(sourceApp: SharedPubkyKeychain.ringSourceApp, pubky: pubky) { query, result in
                    let query = query as NSDictionary
                    XCTAssertEqual(query[kSecAttrAccount] as? String, "\(SharedPubkyKeychain.ringSourceApp):\(pubky)")
                    result?.pointee = testCase.data as CFTypeRef?
                    return testCase.status
                }
            }
            if testCase.fails {
                XCTAssertThrowsError(try read())
            } else {
                XCTAssertEqual(try read(), testCase.expected)
            }
        }
    }
}
