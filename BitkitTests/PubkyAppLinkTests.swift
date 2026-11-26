@testable import Bitkit
import Paykit
import XCTest

final class PubkyAppLinkTests: XCTestCase {
    private let emoji = "\u{1F680}"

    private func error(_ label: String, _ url: String, webOnly: Bool = true) -> PubkyAppLinkError? {
        PubkyAppProfileStore.linkError(label: label, url: url, webOnly: webOnly)
    }

    func testLabelsAreLimitedTo100ScalarsWithEmojiCountedOnce() {
        XCTAssertNil(error(String(repeating: emoji, count: 100), "example.com"))
        XCTAssertEqual(error(String(repeating: emoji, count: 101), "example.com"), .labelTooLong)
        XCTAssertNil(error("  " + String(repeating: "a", count: 100) + "\n", "example.com"))
    }

    func testUrlsAreLimitedTo300ScalarsAfterNormalization() {
        let at300 = "https://example.com/" + String(repeating: "a", count: 280)
        XCTAssertEqual(at300.unicodeScalars.count, 300)
        XCTAssertNil(error("Site", at300))
        XCTAssertEqual(error("Site", at300 + "a"), .urlTooLong)
        XCTAssertEqual(error("Site", "example.com/" + String(repeating: "a", count: 281)), .urlTooLong)
        XCTAssertNil(error("Site", "https://example.com/" + String(repeating: emoji, count: 280)))
        XCTAssertEqual(error("Site", "https://example.com/" + String(repeating: emoji, count: 281)), .urlTooLong)
    }

    func testInvalidUrlsAreRefused() {
        for url in ["not a url", "example", "https://exa mple.com", "https://1.2.3.999"] {
            XCTAssertEqual(error("Site", url, webOnly: false), .urlInvalid, url)
        }
    }

    func testNormalizableInputsAreAccepted() {
        for url in ["example.com", " www.example.com/path ", "https://Example.com", "HTTPS://example.com"] {
            XCTAssertNil(error("Site", url), url)
        }
        for url in ["me@example.com", "+1 (234) 567-890", "mailto:me@example.com", "tel:+123456789"] {
            XCTAssertNil(error("Contact", url, webOnly: false), url)
        }
    }

    func testWebOnlyLinksAcceptIdnUnderscoreAndQueryCharacters() {
        for url in ["bücher.de", "my_site.example.com", "https://example.com/?q=a|b", "https://user:pass@example.com"] {
            XCTAssertNil(error("Site", url), url)
        }
    }

    func testWebOnlyLinksRefuseEmailAndPhone() {
        for url in ["me@example.com", "+1 234 567 890", "mailto:me@example.com", "ftp://example.com"] {
            XCTAssertEqual(error("Contact", url), .urlInvalid, url)
        }
    }

    func testBlankUrlIsLeftToTheCaller() {
        XCTAssertNil(error("Site", "  "))
    }

    func testCharactersTheUrlParserAcceptsInAPathOrQueryAreAccepted() {
        for url in [
            "https://example.com/?q=a|b",
            "https://example.com/100%",
            "https://example.com/a[1]{2}^\"x\"",
            "https://my_site.example.com",
        ] {
            XCTAssertNil(error("Site", url, webOnly: false), url)
            XCTAssertEqual(PubkyAppProfileStore.linkUrl(url), url, url)
        }
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("example.com/?q=a|b"), "https://example.com/?q=a|b")
    }

    func testHostsPortsAndControlCharactersTheUrlParserRefusesAreRefused() {
        for url in [
            "https://exa|mple.com",
            "https://exa%mple.com",
            "https://",
            "https://example.com:65536",
            "https://example.com:port",
            "https://[zz::1]",
            "https://example.com/\u{01}",
            "mailto:a\u{7F}@example.com",
        ] {
            XCTAssertEqual(error("Site", url, webOnly: false), .urlInvalid, url)
        }
        XCTAssertNil(error("Site", "https://example.com:65535", webOnly: false))
        XCTAssertNil(error("Site", "https://example.com."))
        XCTAssertNil(error("Site", "https://1.2.3.4.", webOnly: false))
        XCTAssertNil(error("Site", "https:example.com", webOnly: false))
        XCTAssertEqual(error("Site", "https:example.com"), .urlInvalid)
        XCTAssertNil(error("Site", "https://[::1]:8080", webOnly: false))
    }

    func testLabelEmptyOnceOnOneLineIsRefusedAfterTheUrl() {
        XCTAssertEqual(error("\u{01}\u{02}", "example.com"), .labelEmpty)
        XCTAssertEqual(error("", "example.com"), .labelEmpty)
        XCTAssertEqual(error("", "not a url"), .urlInvalid)
    }

    func testStoredLinkWithoutHostIsRefusedOnceLinksChange() {
        let stored = [PubkyProfileData.Link(label: "Site", url: "https://")]
        let links = stored + [PubkyProfileData.Link(label: "Blog", url: "blog.example.com")]
        XCTAssertEqual(PubkyAppProfileStore.linkErrors(links: links, storedLinks: stored), [0: .urlInvalid])
    }

    func testStoredUrlTheUrlParserAcceptsDoesNotBlockTheSave() {
        let stored = [PubkyProfileData.Link(label: "Search", url: "https://example.com/?q=a|b")]
        let links = stored + [PubkyProfileData.Link(label: "Blog", url: "blog.example.com")]
        XCTAssertTrue(PubkyAppProfileStore.linkErrors(links: links, storedLinks: stored).isEmpty)
    }

    func testOnlyTheNonWebLinkContextOfPaykit011rc9MarksARow() {
        // Paykit 0.1.1-rc9, paykit-sdk/src/domain/contacts/pubky_app.rs; update with the Paykit version.
        XCTAssertEqual(
            PubkyAppProfileStore.paykitNonWebLinkContext,
            "Pubky profile link URL must be a canonical http or https URL"
        )
        let links = [PubkyProfileData.Link(label: "Email", url: "mailto:me@example.com")]
        let invalidUri: PaykitError = .Protocol(code: "protocol_error", context: "Pubky profile link URL must be a valid URI")
        XCTAssertNil(PubkyAppProfileStore.rejectedLinkIndex(for: invalidUri, links: links))
    }

    func testStoredLinksAreNotCheckedWhileUnchanged() {
        let stored = [PubkyProfileData.Link(label: String(repeating: "x", count: 101), url: "https://example.com")]
        XCTAssertTrue(PubkyAppProfileStore.linkErrors(links: stored, storedLinks: stored).isEmpty)
    }

    func testStoredLinkIsCheckedOnceLinksChange() {
        let stored = [
            PubkyProfileData.Link(label: String(repeating: "x", count: 101), url: "https://example.com"),
            PubkyProfileData.Link(label: "Email", url: "mailto:me@example.com"),
        ]
        let links = stored + [PubkyProfileData.Link(label: "Blog", url: "blog.example.com")]
        XCTAssertEqual(PubkyAppProfileStore.linkErrors(links: links, storedLinks: stored), [0: .labelTooLong])
    }

    func testAddedLinkIsHeldToThePublisherRules() {
        let stored = [PubkyProfileData.Link(label: "Website", url: "https://example.com")]
        let links = stored + [
            PubkyProfileData.Link(label: "Email", url: "me@example.com"),
            PubkyProfileData.Link(label: "Site", url: "example.com/" + String(repeating: "a", count: 281)),
        ]
        XCTAssertEqual(PubkyAppProfileStore.linkErrors(links: links, storedLinks: stored), [1: .urlInvalid, 2: .urlTooLong])
    }

    func testLinkRejectionPointsToTheStoredNonWebLink() {
        let links = [
            PubkyProfileData.Link(label: "Site", url: "https://example.com"),
            PubkyProfileData.Link(label: "Email", url: "mailto:me@example.com"),
        ]
        let rejection: PaykitError = .Protocol(
            code: "protocol_error",
            context: "Pubky profile link URL must be a canonical http or https URL"
        )
        XCTAssertEqual(PubkyAppProfileStore.rejectedLinkIndex(for: rejection, links: links), 1)
        let other: PaykitError = .Protocol(code: "protocol_error", context: "Pubky profile name must be 3 to 50 characters")
        XCTAssertNil(PubkyAppProfileStore.rejectedLinkIndex(for: other, links: links))
        XCTAssertEqual(
            PubkyAppProfileStore.linkErrors(links: links + [], storedLinks: [], rejectedIndex: 1)[1],
            .urlInvalid
        )
    }
}
