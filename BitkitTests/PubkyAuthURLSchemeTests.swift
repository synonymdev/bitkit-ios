@testable import Bitkit
import XCTest

final class PubkyAuthURLSchemeTests: XCTestCase {
    func testAppRegistersPubkyAuthAsInboundURLScheme() throws {
        let urlTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(schemes.contains("pubkyauth"))
    }
}
