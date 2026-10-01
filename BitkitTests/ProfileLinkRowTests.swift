@testable import Bitkit
import XCTest

final class ProfileLinkRowTests: XCTestCase {
    func testBareDomainOpensOverHttps() {
        XCTAssertEqual(ProfileLinkRow.destination(for: "github.com")?.absoluteString, "https://github.com")
        XCTAssertEqual(ProfileLinkRow.destination(for: "x.com/satoshi")?.absoluteString, "https://x.com/satoshi")
    }

    func testExplicitSchemesAreKept() {
        XCTAssertEqual(ProfileLinkRow.destination(for: "https://bitcoin.org")?.absoluteString, "https://bitcoin.org")
        XCTAssertEqual(ProfileLinkRow.destination(for: "mailto:satoshi@gmx.com")?.absoluteString, "mailto:satoshi@gmx.com")
        XCTAssertEqual(ProfileLinkRow.destination(for: "tel:+15551234")?.absoluteString, "tel:+15551234")
    }

    func testSchemeCaseIsIgnored() {
        XCTAssertEqual(ProfileLinkRow.destination(for: "Https://example.com")?.absoluteString, "Https://example.com")
    }

    func testInternationalPhoneNumberOpensDialer() {
        XCTAssertEqual(ProfileLinkRow.destination(for: "+15551234")?.absoluteString, "tel:+15551234")
        XCTAssertEqual(ProfileLinkRow.destination(for: "+1 (555) 123-4567")?.absoluteString, "tel:+15551234567")
    }

    func testLocalNumberOpensDialerUnderPhoneLabel() {
        XCTAssertEqual(ProfileLinkRow.destination(for: "555 123 4567", label: "Phone")?.absoluteString, "tel:5551234567")
        XCTAssertNil(ProfileLinkRow.destination(for: "555 123 4567", label: "Notes"))
    }

    func testNumericTextStaysPlain() {
        XCTAssertNil(ProfileLinkRow.destination(for: "2024"))
        XCTAssertNil(ProfileLinkRow.destination(for: "192.168.1.100"))
        XCTAssertNil(ProfileLinkRow.destination(for: "2024-01-01"))
        XCTAssertNil(ProfileLinkRow.destination(for: "2024.01.01"))
    }

    func testFormattedTelLinkOpensDialer() {
        XCTAssertEqual(ProfileLinkRow.destination(for: "tel:+1 555 123 4567")?.absoluteString, "tel:+15551234567")
        XCTAssertEqual(ProfileLinkRow.destination(for: "TEL:+1 (555) 123-4567")?.absoluteString, "tel:+15551234567")
    }

    func testEmailOpensMail() {
        XCTAssertEqual(ProfileLinkRow.destination(for: "satoshin@gmx.com")?.absoluteString, "mailto:satoshin@gmx.com")
    }

    func testPlainTextIsNotALink() {
        XCTAssertNil(ProfileLinkRow.destination(for: "@satoshinakamoto"))
        XCTAssertNil(ProfileLinkRow.destination(for: "Ask me in person"))
        XCTAssertNil(ProfileLinkRow.destination(for: ""))
        XCTAssertNil(ProfileLinkRow.destination(for: "javascript:alert(1)"))
    }
}
