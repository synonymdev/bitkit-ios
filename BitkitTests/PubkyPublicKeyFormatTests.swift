@testable import Bitkit
import XCTest

final class PubkyPublicKeyFormatTests: XCTestCase {
    private let rawKey = "deadbeefxyz123456789abcdefghijklmnopqrstuvwxyz0poxyo"

    func testDisplayTruncatedStripsPubkyPrefix() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pubky\(rawKey)"), "deadb...poxyo")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("PUBKY\(rawKey)"), "deadb...poxyo")
    }

    func testDisplayTruncatedStripsPkPrefix() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pk:\(rawKey)"), "deadb...poxyo")
    }

    func testDisplayTruncatedHandlesUnprefixedKey() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated(rawKey), "deadb...poxyo")
    }

    func testDisplayTruncatedTrimsSurroundingWhitespace() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("  pubky\(rawKey)\n"), "deadb...poxyo")
    }

    func testDisplayTruncatedNeverShowsPrefix() {
        XCTAssertFalse(PubkyPublicKeyFormat.displayTruncated("pubky\(rawKey)").hasPrefix("pubky"))
        XCTAssertFalse(PubkyPublicKeyFormat.displayTruncated("pk:\(rawKey)").hasPrefix("pk:"))
    }

    func testDisplayTruncatedReturnsShortValuesUnchanged() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("abc"), "abc")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("1234567890"), "1234567890")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated(""), "")
    }

    func testDisplayTruncatedStripsPrefixFromShortValues() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pubkyabc"), "abc")
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("pk:abc"), "abc")
    }

    func testDisplayTruncatedTruncatesJustOverBoundary() {
        XCTAssertEqual(PubkyPublicKeyFormat.displayTruncated("12345678901"), "12345...78901")
    }
}
