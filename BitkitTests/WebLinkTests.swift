@testable import Bitkit
import XCTest

final class WebLinkTests: XCTestCase {
    func testWebLinksAreAcceptedWithOrWithoutTheirScheme() {
        for link in ["https://example.com", "http://example.com/a?b=c", "example.com", " www.example.com/path "] {
            XCTAssertTrue(link.isWebLink, link)
        }
    }

    func testLinksASocialV1ProfileRejectsAreRefused() {
        let links = [
            "mailto:a@b.c", "a@b.c", "tel:+123456789", "+1 234 567 890", "123.456.7890",
            "ftp://example.com", "example.com:8080", "example", "two words.com", "",
        ]
        for link in links {
            XCTAssertFalse(link.isWebLink, link)
        }
    }
}
