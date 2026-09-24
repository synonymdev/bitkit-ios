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
