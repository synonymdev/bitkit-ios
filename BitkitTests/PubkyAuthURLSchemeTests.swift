@testable import Bitkit
import XCTest

final class PubkyAuthURLSchemeTests: XCTestCase {
    func testAppRegistersPubkyAuthAsInboundURLScheme() throws {
        let urlTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(schemes.contains("pubkyauth"))
    }

    func testAppQueriesPubkyRingSpecificOutboundURLScheme() throws {
        let schemes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])

        XCTAssertTrue(schemes.contains("pubkyring"))
    }

    @MainActor
    func testAppRetainsPubkyAuthURLUntilMainNavigationConsumesIt() throws {
        let app = AppViewModel()
        let url = try XCTUnwrap(URL(string: "pubkyauth://signin?x-bitkit-claim=watch-only-account-v1"))

        app.retainDeepLink(url)

        XCTAssertEqual(app.pendingDeepLinkURL, url)
        XCTAssertEqual(app.takePendingDeepLink(), url)
        XCTAssertNil(app.pendingDeepLinkURL)
        XCTAssertNil(app.takePendingDeepLink())
    }
}
