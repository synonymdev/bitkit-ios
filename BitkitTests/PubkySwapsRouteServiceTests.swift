@testable import Bitkit
import XCTest

final class PubkySwapsRouteServiceTests: XCTestCase {
    private let provider = "pubky" + String(repeating: "a", count: 52)
    private let contact = String(repeating: "b", count: 52)

    func testCandidatesPutConfiguredProvidersFirstAndAskEachKeyOnce() {
        let providerContact = String(provider.dropFirst("pubky".count))
        XCTAssertEqual(
            PubkySwapsRouteService.candidates(contacts: [contact, providerContact, contact], providers: [provider]),
            [provider, contact]
        )
    }
}
