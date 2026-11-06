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
}
