@testable import Bitkit
import XCTest

final class PubkyModelTests: XCTestCase {
    // MARK: - PubkyProfile Truncation

    func testTruncatedPublicKeyLongKey() {
        let profile = PubkyProfile(
            publicKey: "pubkyz6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK",
            name: "Test",
            bio: "",
            imageUrl: nil,
            links: [],
            status: nil
        )

        XCTAssertEqual(profile.truncatedPublicKey, "pubk...2doK")
    }

    func testTruncatedPublicKeyShortKey() {
        let profile = PubkyProfile(
            publicKey: "abc",
            name: "Test",
            bio: "",
            imageUrl: nil,
            links: [],
            status: nil
        )

        // Keys <= 10 chars are returned as-is
        XCTAssertEqual(profile.truncatedPublicKey, "abc")
    }

    func testTruncatedPublicKeyExactBoundary() {
        let profile = PubkyProfile(
            publicKey: "1234567890",
            name: "Test",
            bio: "",
            imageUrl: nil,
            links: [],
            status: nil
        )

        // Exactly 10 chars should NOT be truncated
        XCTAssertEqual(profile.truncatedPublicKey, "1234567890")
    }

    func testTruncatedPublicKeyElevenChars() {
        let profile = PubkyProfile(
            publicKey: "12345678901",
            name: "Test",
            bio: "",
            imageUrl: nil,
            links: [],
            status: nil
        )

        // 11 chars should be truncated
        XCTAssertEqual(profile.truncatedPublicKey, "1234...8901")
    }

    // MARK: - PubkyProfile Placeholder

    func testPlaceholderUsesKeyAsName() {
        let placeholder = PubkyProfile.placeholder(publicKey: "pubkyz6MkhaXgBZDvotDk")

        XCTAssertEqual(placeholder.publicKey, "pubkyz6MkhaXgBZDvotDk")
        XCTAssertEqual(placeholder.name, "pubk...otDk")
        XCTAssertTrue(placeholder.bio.isEmpty)
        XCTAssertNil(placeholder.imageUrl)
        XCTAssertTrue(placeholder.links.isEmpty)
        XCTAssertNil(placeholder.status)
    }

    func testPlaceholderShortKeyUsesFullKey() {
        let placeholder = PubkyProfile.placeholder(publicKey: "short")

        XCTAssertEqual(placeholder.name, "short")
    }

    // MARK: - PubkyProfile Initialization

    func testProfileInitWithAllFields() {
        let links = [PubkyProfileLink(label: "X", url: "https://x.com/user")]
        let profile = PubkyProfile(
            publicKey: "pk1",
            name: "Satoshi",
            bio: "Creator",
            imageUrl: "https://example.com/avatar.png",
            links: links,
            status: "online"
        )

        XCTAssertEqual(profile.name, "Satoshi")
        XCTAssertEqual(profile.bio, "Creator")
        XCTAssertEqual(profile.imageUrl, "https://example.com/avatar.png")
        XCTAssertEqual(profile.links.count, 1)
        XCTAssertEqual(profile.links.first?.label, "X")
        XCTAssertEqual(profile.status, "online")
    }

    // MARK: - PubkyContact

    func testContactDisplayName() {
        let profile = PubkyProfile(
            publicKey: "pk1",
            name: "Alice",
            bio: "",
            imageUrl: nil,
            links: [],
            status: nil
        )
        let contact = PubkyContact(publicKey: "pk1", profile: profile)

        XCTAssertEqual(contact.displayName, "Alice")
    }

    func testContactSortLetterAlpha() {
        let profile = PubkyProfile(publicKey: "pk1", name: "Bob", bio: "", imageUrl: nil, links: [], status: nil)
        let contact = PubkyContact(publicKey: "pk1", profile: profile)

        XCTAssertEqual(contact.sortLetter, "B")
    }

    func testContactSortLetterNumeric() {
        let profile = PubkyProfile(publicKey: "pk1", name: "42", bio: "", imageUrl: nil, links: [], status: nil)
        let contact = PubkyContact(publicKey: "pk1", profile: profile)

        XCTAssertEqual(contact.sortLetter, "#")
    }

    func testContactSortLetterEmoji() {
        let profile = PubkyProfile(publicKey: "pk1", name: "🎉Party", bio: "", imageUrl: nil, links: [], status: nil)
        let contact = PubkyContact(publicKey: "pk1", profile: profile)

        XCTAssertEqual(contact.sortLetter, "#")
    }

    func testContactEquality() {
        let profile1 = PubkyProfile(publicKey: "pk1", name: "Alice", bio: "", imageUrl: nil, links: [], status: nil)
        let profile2 = PubkyProfile(publicKey: "pk1", name: "Alice Updated", bio: "new bio", imageUrl: nil, links: [], status: nil)

        let contact1 = PubkyContact(publicKey: "pk1", profile: profile1)
        let contact2 = PubkyContact(publicKey: "pk1", profile: profile2)

        // Equality is based on publicKey, not profile contents
        XCTAssertEqual(contact1, contact2)
    }

    func testContactInequality() {
        let profile1 = PubkyProfile(publicKey: "pk1", name: "Alice", bio: "", imageUrl: nil, links: [], status: nil)
        let profile2 = PubkyProfile(publicKey: "pk2", name: "Alice", bio: "", imageUrl: nil, links: [], status: nil)

        let contact1 = PubkyContact(publicKey: "pk1", profile: profile1)
        let contact2 = PubkyContact(publicKey: "pk2", profile: profile2)

        XCTAssertNotEqual(contact1, contact2)
    }

    // MARK: - ContactSection

    func testContactSectionId() {
        let section = ContactSection(id: "A", letter: "A", contacts: [])

        XCTAssertEqual(section.id, "A")
        XCTAssertEqual(section.letter, "A")
        XCTAssertTrue(section.contacts.isEmpty)
    }

    // MARK: - PubkyProfileLink

    func testProfileLinkUniqueIds() {
        let link1 = PubkyProfileLink(label: "X", url: "https://x.com")
        let link2 = PubkyProfileLink(label: "X", url: "https://x.com")

        XCTAssertNotEqual(link1.id, link2.id)
    }

    // MARK: - PubkyProfileData Decoding

    func testProfileDataDecodesWithTags() throws {
        let json = """
        {"name":"Satoshi","bio":"","image":null,"links":[],"tags":["bitcoin","lightning"]}
        """
        let data = try PubkyProfileData.decode(from: json)

        XCTAssertEqual(data.name, "Satoshi")
        XCTAssertEqual(data.tags, ["bitcoin", "lightning"])
    }

    func testProfileDataDecodesWithoutTags() throws {
        let json = """
        {"name":"Satoshi","bio":"","image":null,"links":[]}
        """
        let data = try PubkyProfileData.decode(from: json)

        XCTAssertEqual(data.name, "Satoshi")
        XCTAssertEqual(data.tags, [])
    }

    func testProfileDataRoundTrip() throws {
        let original = PubkyProfileData(
            name: "Alice",
            bio: "Test bio",
            image: "pubky://abc/pub/bitkit.to/blobs/123.jpg",
            links: [PubkyProfileData.Link(label: "Website", url: "https://example.com")],
            tags: ["dev", "bitcoin"]
        )

        let encoded = try original.encoded()
        let decoded = try JSONDecoder().decode(PubkyProfileData.self, from: encoded)

        XCTAssertEqual(decoded.name, "Alice")
        XCTAssertEqual(decoded.bio, "Test bio")
        XCTAssertEqual(decoded.image, "pubky://abc/pub/bitkit.to/blobs/123.jpg")
        XCTAssertEqual(decoded.links.count, 1)
        XCTAssertEqual(decoded.links.first?.label, "Website")
        XCTAssertEqual(decoded.tags, ["dev", "bitcoin"])
    }

    func testProfileDataToProfile() {
        let data = PubkyProfileData(
            name: "Bob",
            bio: "Hello",
            image: "pubky://key/pub/bitkit.to/blobs/avatar.jpg",
            links: [PubkyProfileData.Link(label: "X", url: "https://x.com/bob")],
            tags: ["design"]
        )

        let profile = data.toProfile(publicKey: "pubkyTestKey123")

        XCTAssertEqual(profile.publicKey, "pubkyTestKey123")
        XCTAssertEqual(profile.name, "Bob")
        XCTAssertEqual(profile.bio, "Hello")
        XCTAssertEqual(profile.tags, ["design"])
        XCTAssertEqual(profile.links.count, 1)
        XCTAssertEqual(profile.links.first?.url, "https://x.com/bob")
    }

    func testProfileDataFromProfile() {
        let profile = PubkyProfile(
            publicKey: "pk1",
            name: "Alice",
            bio: "Bio",
            imageUrl: "pubky://img",
            links: [PubkyProfileLink(label: "Site", url: "https://a.com")],
            tags: ["swift", "ios"],
            status: "active"
        )

        let data = PubkyProfileData.from(profile: profile)

        XCTAssertEqual(data.name, "Alice")
        XCTAssertEqual(data.bio, "Bio")
        XCTAssertEqual(data.image, "pubky://img")
        XCTAssertEqual(data.tags, ["swift", "ios"])
        XCTAssertEqual(data.links.count, 1)
    }
}
