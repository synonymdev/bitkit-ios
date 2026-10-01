@testable import Bitkit
import XCTest

final class PubkyChoiceViewTests: XCTestCase {
    func testDescriptionKeyWithRingIdentities() {
        XCTAssertEqual(PubkyChoiceView.descriptionKey(hasRingIdentities: true), "profile__choice_description_ring")
    }

    func testDescriptionKeyWithoutRingIdentities() {
        XCTAssertEqual(PubkyChoiceView.descriptionKey(hasRingIdentities: false), "profile__choice_description")
    }

    func testCreateCardOnlyWithoutRingIdentities() {
        XCTAssertFalse(PubkyChoiceView.showsCreateCard(hasRingIdentities: true))
        XCTAssertTrue(PubkyChoiceView.showsCreateCard(hasRingIdentities: false))
    }

    func testMirroredRingProfilesEqualTheFoundProfilesWhenNotAdopting() {
        let shown = ["alice": profile("alice", name: "Alice"), "bob": profile("bob", name: "Bob")]
        let found = ["alice": profile("alice", name: "Alice Renamed")]

        let mirrored = PubkyChoiceView.mirroredRingProfiles(shown, found: found, isAdopting: false)

        XCTAssertEqual(mirrored.mapValues(\.name), ["alice": "Alice Renamed"], "A row whose lookup now finds nothing drops its old profile")
    }

    func testMirroredRingProfilesOnlyAddWhileAdopting() {
        let shown = ["alice": profile("alice", name: "Alice"), "bob": profile("bob", name: "Bob")]
        let found = ["alice": profile("alice", name: "Alice Renamed"), "carol": profile("carol", name: "Carol")]

        let cleared = PubkyChoiceView.mirroredRingProfiles(shown, found: [:], isAdopting: true)
        let merged = PubkyChoiceView.mirroredRingProfiles(shown, found: found, isAdopting: true)

        XCTAssertEqual(cleared.mapValues(\.name), ["alice": "Alice", "bob": "Bob"], "Rows keep their profiles while adopting clears the cache")
        XCTAssertEqual(merged.mapValues(\.name), ["alice": "Alice Renamed", "bob": "Bob", "carol": "Carol"])
    }

    func testRingLookupShowsOnlyForARowStillLookingUpWithoutAProfileThatIsNotBeingAdopted() {
        XCTAssertTrue(PubkyChoiceView.showsRingLookup(isLookingUp: true, hasProfile: false, isAdoptingRow: false))
        XCTAssertFalse(
            PubkyChoiceView.showsRingLookup(isLookingUp: false, hasProfile: false, isAdoptingRow: false),
            "A finished lookup brings back the avatar"
        )
        XCTAssertFalse(
            PubkyChoiceView.showsRingLookup(isLookingUp: true, hasProfile: true, isAdoptingRow: false),
            "A found profile replaces the spinner"
        )
        XCTAssertFalse(
            PubkyChoiceView.showsRingLookup(isLookingUp: true, hasProfile: false, isAdoptingRow: true),
            "The adopting row shows only its key-icon spinner"
        )
        XCTAssertFalse(PubkyChoiceView.showsRingLookup(isLookingUp: true, hasProfile: true, isAdoptingRow: true))
        XCTAssertFalse(PubkyChoiceView.showsRingLookup(isLookingUp: false, hasProfile: true, isAdoptingRow: false))
        XCTAssertFalse(PubkyChoiceView.showsRingLookup(isLookingUp: false, hasProfile: false, isAdoptingRow: true))
        XCTAssertFalse(PubkyChoiceView.showsRingLookup(isLookingUp: false, hasProfile: true, isAdoptingRow: true))
    }

    private func profile(_ publicKey: String, name: String) -> PubkyProfile {
        .forDisplay(publicKey: publicKey, name: name, imageUrl: nil)
    }
}
