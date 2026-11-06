@testable import Bitkit
import XCTest

final class PubkyAppProfileStoreTests: XCTestCase {
    private let base = PubkyProfile(
        publicKey: "pubkytest",
        name: "Alice",
        bio: "Bio",
        imageUrl: "pubky://test/pub/pubky.app/files/0000000000000",
        links: [PubkyProfileLink(label: "X", url: "https://x.com/alice")],
        status: "away"
    )

    private func data(name: String = "Alice", bio: String = "Bio", image: String? = nil, links: [PubkyProfileData.Link]? = nil)
        -> PubkyProfileData
    {
        PubkyProfileData(
            name: name,
            bio: bio,
            image: image ?? base.imageUrl,
            links: links ?? [.init(label: "X", url: "https://x.com/alice")],
            tags: []
        )
    }

    func testUnchangedFieldsAreLeftOut() {
        let update = PubkyAppProfileStore.update(from: data(name: "Alicia"), base: base)

        XCTAssertEqual(update.name, "Alicia")
        XCTAssertNil(update.bio)
        XCTAssertNil(update.image)
        XCTAssertNil(update.links)
    }

    func testRemovedImageAndLinksAreCleared() {
        var edited = data(links: [])
        edited.image = nil

        let update = PubkyAppProfileStore.update(from: edited, base: base)

        XCTAssertEqual(update.image, "")
        XCTAssertEqual(update.links?.isEmpty, true)
        XCTAssertNil(update.name)
    }

    func testWithoutBaseEveryFieldIsWritten() {
        let update = PubkyAppProfileStore.update(from: data(), base: nil)

        XCTAssertEqual(update.name, "Alice")
        XCTAssertEqual(update.bio, "Bio")
        XCTAssertEqual(update.image, base.imageUrl)
        XCTAssertEqual(update.links?.first?.title, "X")
    }

    func testLinksWithoutSchemeBecomeFullUrls() {
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("example.com"), "https://example.com")
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("alice@example.com"), "mailto:alice@example.com")
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("+49 123 456"), "tel:+49123456")
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("https://x.com/alice"), "https://x.com/alice")
        XCTAssertNil(PubkyAppProfileStore.linkUrl("  "))
    }

    func testFreeTextIsNotMadeALink() {
        XCTAssertNil(PubkyAppProfileStore.linkUrl("my site"))
        XCTAssertNil(PubkyAppProfileStore.linkUrl("12345"))
        XCTAssertNil(PubkyAppProfileStore.linkUrl("a@b"))
        XCTAssertNil(PubkyAppProfileStore.linkUrl("2024-01-01"))
        XCTAssertNil(PubkyAppProfileStore.linkUrl("New York"))
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("medium.com/@alice"), "https://medium.com/@alice")
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("example.com/a@b"), "https://example.com/a@b")
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("0123 456 789"), "tel:0123456789")
    }

    func testOnlyControlCharactersAreFlattened() {
        XCTAssertEqual(PubkyAppProfileStore.singleLine("Builder\nMaker"), "Builder Maker")
        XCTAssertEqual(PubkyAppProfileStore.singleLine("👩\u{200D}💻 می\u{200C}خواهم"), "👩\u{200D}💻 می\u{200C}خواهم")
    }

    func testCapsCountUnicodeScalars() {
        XCTAssertNil(PubkyAppProfileLimits.capped("abc", to: 3))
        XCTAssertEqual(PubkyAppProfileLimits.capped("👩\u{200D}💻x", to: 3), "👩\u{200D}💻")
        XCTAssertFalse(PubkyAppProfileLimits.isValidName("é\u{301}"))
        XCTAssertTrue(PubkyAppProfileLimits.isValidName("e\u{301}e"))
    }

    func testProfileWithoutBaseIsFittedToPubkyAppLimits() {
        let links = (1 ... 6).map { PubkyProfileData.Link(label: "Site \($0)", url: "site\($0).com") }
            + [.init(label: "City", url: "New York")]
        let fitted = PubkyAppProfileStore.fitted(
            PubkyProfileData(
                name: "Alice",
                bio: String(repeating: "b", count: 200),
                image: nil,
                links: [.init(label: "City", url: "New York")] + links,
                tags: []
            )
        )

        XCTAssertEqual(fitted.bio.unicodeScalars.count, 160)
        XCTAssertEqual(fitted.links.count, 5)
        XCTAssertEqual(fitted.links.first?.url, "https://site1.com")
        XCTAssertFalse(fitted.links.contains { $0.label == "City" })
    }
}
