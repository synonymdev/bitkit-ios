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
}
