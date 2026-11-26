@testable import Bitkit
import Paykit
import XCTest

final class PubkyAppProfileStoreTests: XCTestCase {
    func testSavingOriginalRestoreFormAfterRefreshPublishesExistingAndNewTags() async throws {
        let ownersKey = "pubky_app_profile_owners"
        let avatarPendingKey = "pubky_app_avatar_pending"
        let defaults = UserDefaults.standard
        let previousOwners = defaults.object(forKey: ownersKey)
        let previousPendingAvatars = defaults.object(forKey: avatarPendingKey)
        defer {
            defaults.set(previousOwners, forKey: ownersKey)
            defaults.set(previousPendingAvatars, forKey: avatarPendingKey)
        }

        let publicKey = String(repeating: "b", count: 52)
        let existingTags = ["friend", "work"]
        let paykitCopy = PubkyProfileData(name: "Alice", bio: "", image: nil, links: [], tags: existingTags)
        let profile = Paykit.PubkyProfile(name: "Alice", bio: nil, image: nil, links: [], status: nil)
        let snapshot = Paykit.PubkyProfileSnapshot(publicKey: publicKey, profile: profile, revision: "original", fetchedAt: "")
        let paykit = try RestoreProfileCopyStub(record: .init(
            publicKey: publicKey,
            profile: paykitCopy.toPaykitProfile(),
            path: "/pub/paykit/profile.json",
            revision: "copy",
            updatedAt: ""
        ))
        let store = PubkyAppProfileStore(profileIO: .init(
            currentPublicKey: { publicKey },
            fetchPaykitProfile: { _ in try await paykit.fetch() },
            fetchPubkyProfile: { _ in snapshot },
            publishPubkyProfile: { _, _, _ in snapshot },
            publishPaykitProfile: { profile, _ in await paykit.publish(profile) }
        ))

        let original = try await store.load(publicKey: publicKey)
        XCTAssertTrue(original.tagsUnread)
        XCTAssertEqual(original.tags, [])
        let revision = try XCTUnwrap(original.revision)

        let refreshed = try await store.load(publicKey: publicKey)
        XCTAssertFalse(refreshed.tagsUnread)
        XCTAssertEqual(refreshed.tags, existingTags)
        let writesBeforeSave = await paykit.publishedTags.count

        var form = PubkyProfileData.from(profile: original)
        form.baseRevision = revision
        form.baseTagsUnread = original.tagsUnread
        form.tags.append("vip")
        try await store.save(form, expectedIdentity: publicKey)

        let writesFromSave = await paykit.publishedTags.dropFirst(writesBeforeSave)
        XCTAssertEqual(Array(writesFromSave), [existingTags + ["vip"]])
    }

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
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("555.123.4567"), "tel:5551234567")
        XCTAssertNil(PubkyAppProfileStore.linkUrl("v1.2.3"))
        XCTAssertNil(PubkyAppProfileStore.linkUrl("foo.123"))
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("tel://5551234567"), "tel://5551234567")
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("https://127.1"), "https://127.1")
        XCTAssertEqual(PubkyAppProfileStore.linkUrl("192.168.1.10"), "https://192.168.1.10")
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

    func testFittedProfileKeepsOnlyLinksSocialV1Accepts() {
        let links: [PubkyProfileData.Link] = [
            .init(label: "Mail", url: "alice@example.com"),
            .init(label: "Phone", url: "+49 123 456"),
            .init(label: "Site", url: "example.com"),
            .init(label: "Upper", url: "Https://example.com"),
            .init(label: "Shout", url: "HTTP://example.com/path"),
        ]
        let fitted = PubkyAppProfileStore.fitted(PubkyProfileData(name: "Alice", bio: "", image: nil, links: links, tags: []))

        XCTAssertEqual(fitted.links.map(\.url), ["https://example.com", "https://example.com", "http://example.com/path"])
        XCTAssertTrue(links.filter(\.url.isWebLink).allSatisfy { link in fitted.links.contains { $0.label == link.label } })
    }
}

private actor RestoreProfileCopyStub {
    let record: Paykit.PaykitProfileRecord
    private var isFirstRead = true
    private(set) var publishedTags: [[String]] = []

    init(record: Paykit.PaykitProfileRecord) {
        self.record = record
    }

    func fetch() throws -> Paykit.PaykitProfileRecord {
        if isFirstRead {
            isFirstRead = false
            throw URLError(.notConnectedToInternet)
        }
        return record
    }

    func publish(_ profile: Paykit.PaykitProfile) {
        publishedTags.append(PubkyProfileData.from(paykitProfile: profile).tags)
    }
}

final class ProfileWriteGateTests: XCTestCase {
    func testWriteFromBeforeADeletionIsRefused() {
        var gate = ProfileWriteGate()
        let generation = gate.generation("a")

        gate.beginDeletion("a")
        gate.endDeletion("a")

        XCTAssertThrowsError(try gate.admit("a", generation: generation))
        XCTAssertNoThrow(try gate.admit("a", generation: gate.generation("a")))
    }

    func testNoWriteIsAdmittedDuringADeletion() {
        var gate = ProfileWriteGate()

        gate.beginDeletion("a")
        let startedDuring = gate.generation("a")

        XCTAssertThrowsError(try gate.admit("a", generation: startedDuring))
        gate.endDeletion("a")
        XCTAssertThrowsError(try gate.admit("a", generation: startedDuring))
        XCTAssertNoThrow(try gate.admit("b", generation: gate.generation("b")))
    }

    func testCopyRefreshFromBeforeASaveIsRefused() {
        var gate = ProfileWriteGate()
        let readBeforeSave = gate.copyEpoch("a")

        gate.beginSave("a")
        gate.endSave("a")

        XCTAssertFalse(gate.mayRefreshCopy("a", epoch: readBeforeSave))
        XCTAssertTrue(gate.mayRefreshCopy("a", epoch: gate.copyEpoch("a")))
    }

    func testNoCopyRefreshDuringASave() {
        var gate = ProfileWriteGate()

        gate.beginSave("a")
        let readDuringSave = gate.copyEpoch("a")

        XCTAssertFalse(gate.mayRefreshCopy("a", epoch: readDuringSave))
        gate.endSave("a")
        XCTAssertFalse(gate.mayRefreshCopy("a", epoch: readDuringSave))
        XCTAssertTrue(gate.mayRefreshCopy("b", epoch: gate.copyEpoch("b")))
    }

    func testNoCopyRefreshDuringOverlappingSaves() {
        var gate = ProfileWriteGate()

        gate.beginSave("a")
        gate.beginSave("a")
        let readDuringSaves = gate.copyEpoch("a")

        XCTAssertFalse(gate.mayRefreshCopy("a", epoch: readDuringSaves))
        gate.endSave("a")
        XCTAssertFalse(gate.mayRefreshCopy("a", epoch: readDuringSaves))
        gate.endSave("a")
        XCTAssertFalse(gate.mayRefreshCopy("a", epoch: readDuringSaves))
        XCTAssertTrue(gate.mayRefreshCopy("a", epoch: gate.copyEpoch("a")))
    }

    func testDeletionWaitsForWritesUnderWay() async throws {
        actor Box {
            var gate = ProfileWriteGate()
            var settled = false
            func admit() throws {
                try gate.admit("a", generation: gate.generation("a"))
            }

            func end() {
                gate.end("a")
            }

            func delete() async {
                gate.beginDeletion("a")
                if gate.hasWritesInFlight("a") {
                    await withCheckedContinuation { gate.onWritesSettled("a", $0) }
                }
                settled = true
            }
        }
        let box = Box()
        try await box.admit()
        try await box.admit()
        let deletion = Task { await box.delete() }

        await box.end()
        try await Task.sleep(nanoseconds: 50_000_000)
        let settledEarly = await box.settled
        XCTAssertFalse(settledEarly)

        await box.end()
        await deletion.value
        let settled = await box.settled
        XCTAssertTrue(settled)
    }
}
