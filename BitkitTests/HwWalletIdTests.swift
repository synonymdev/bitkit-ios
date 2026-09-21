@testable import Bitkit
import CryptoKit
import XCTest

final class HwWalletIdTests: XCTestCase {
    func testDeterministicForSameXpubs() throws {
        let a = try HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let b = try HwWalletId.derive(xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        XCTAssertEqual(a, b, "id derives deterministically from xpubs")
    }

    /// Pins the exact derivation against an independent reproduction of core's
    /// `derive_wallet_id` (sort values, join with "\n", SHA256, lowercase hex,
    /// prefix "{deviceType}:"). Fails if either core's contract or the Swift call
    /// site (e.g. accidentally folding in the dictionary keys) drifts.
    func testMatchesCanonicalDerivation() throws {
        let xpubs = ["taproot": "zTR", "nativeSegwit": "zNS"]
        let expected = "trezor:" + expectedHash(ofSortedValues: xpubs)
        XCTAssertEqual(try HwWalletId.derive(xpubs: xpubs), expected)
    }

    // The id must depend only on the set of xpub values, never on the address-type
    // keys: the same values mapped to swapped keys yield two genuinely different
    // dictionaries, yet must derive the same id (unlike two equal literals, this
    // can fail if derivation ever starts depending on keys or insertion order).
    func testIndependentOfAddressTypeKeys() throws {
        let a = try HwWalletId.derive(xpubs: ["nativeSegwit": "xpubA", "taproot": "xpubB"])
        let b = try HwWalletId.derive(xpubs: ["taproot": "xpubA", "nativeSegwit": "xpubB"])
        XCTAssertEqual(a, b, "id depends on the value set, not the keys or their order")
    }

    func testDifferentXpubsProduceDifferentIds() throws {
        let a = try HwWalletId.derive(xpubs: ["nativeSegwit": "zNS"])
        let b = try HwWalletId.derive(xpubs: ["nativeSegwit": "DIFFERENT"])
        XCTAssertNotEqual(a, b)
    }

    func testPrefix() throws {
        XCTAssertTrue(try HwWalletId.derive(xpubs: ["nativeSegwit": "z"]).hasPrefix("trezor:"))
    }

    func testThrowsWhenNoXpubs() {
        XCTAssertThrowsError(try HwWalletId.derive(xpubs: [:]))
    }

    private func expectedHash(ofSortedValues xpubs: [String: String]) -> String {
        let joined = xpubs.values.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}
