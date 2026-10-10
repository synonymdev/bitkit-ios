@testable import Bitkit
import XCTest

final class PubkyPublicKeyFormatTests: XCTestCase {
    private let rawKey = "deadbeefxyz123456789abcdefghijklmnopqrstuvwxyz0poxyo"

    func testDisplayTruncatedStripsPubkyPrefix() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pubky\(rawKey)"), "dead...oxyo")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("PUBKY\(rawKey)"), "dead...oxyo")
    }

    func testDisplayTruncatedStripsPkPrefix() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pk:\(rawKey)"), "dead...oxyo")
    }

    func testDisplayTruncatedHandlesUnprefixedKey() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated(rawKey), "dead...oxyo")
    }

    func testDisplayTruncatedTrimsSurroundingWhitespace() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("  pubky\(rawKey)\n"), "dead...oxyo")
    }

    func testDisplayTruncatedNeverShowsPrefix() {
        XCTAssertFalse(PubkyPublicKeyFormat.displayTruncated("pubky\(rawKey)").hasPrefix("pubky"))
        XCTAssertFalse(PubkyPublicKeyFormat.displayTruncated("pk:\(rawKey)").hasPrefix("pk:"))
    }

    func testDisplayTruncatedReturnsShortValuesUnchanged() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("abc"), "abc")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("12345678"), "12345678")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated(""), "")
    }

    func testDisplayTruncatedStripsPrefixFromShortValues() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pubkyabc"), "abc")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pk:abc"), "abc")
    }

    func testDisplayTruncatedTruncatesJustOverBoundary() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("123456789"), "1234...6789")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pubky123456789"), "1234...6789")
    }
}
