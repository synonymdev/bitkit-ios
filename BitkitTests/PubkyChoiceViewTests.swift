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

    func testMirroredRingProfilesEqualTheFoundProfilesButOnlyAddWhileAdopting() {
        let shown = ["alice": profile("alice", name: "Alice"), "bob": profile("bob", name: "Bob")]
        let found = ["alice": profile("alice", name: "Alice Renamed"), "carol": profile("carol", name: "Carol")]
        let cases: [(name: String, found: [String: PubkyProfile], isAdopting: Bool, expected: [String: String])] = [
            ("a row whose lookup now finds nothing drops its old profile", found, false, ["alice": "Alice Renamed", "carol": "Carol"]),
            ("rows keep their profiles while adopting clears the cache", [:], true, ["alice": "Alice", "bob": "Bob"]),
            ("adopting only adds", found, true, ["alice": "Alice Renamed", "bob": "Bob", "carol": "Carol"]),
        ]
        for testCase in cases {
            let mirrored = PubkyChoiceView.mirroredRingProfiles(shown, found: testCase.found, isAdopting: testCase.isAdopting)
            XCTAssertEqual(mirrored.mapValues(\.name), testCase.expected, testCase.name)
        }
    }

    /// A finished lookup brings back the avatar, a found profile replaces the spinner, and the adopting row shows only its
    /// key-icon spinner.
    func testRingLookupShowsOnlyForARowStillLookingUpWithoutAProfileThatIsNotBeingAdopted() {
        for isLookingUp in [true, false] {
            for hasProfile in [true, false] {
                for isAdoptingRow in [true, false] {
                    XCTAssertEqual(
                        PubkyChoiceView.showsRingLookup(isLookingUp: isLookingUp, hasProfile: hasProfile, isAdoptingRow: isAdoptingRow),
                        isLookingUp && !hasProfile && !isAdoptingRow,
                        "isLookingUp: \(isLookingUp), hasProfile: \(hasProfile), isAdoptingRow: \(isAdoptingRow)"
                    )
                }
            }
        }
    }

    private func profile(_ publicKey: String, name: String) -> PubkyProfile {
        .forDisplay(publicKey: publicKey, name: name, imageUrl: nil)
    }
}
