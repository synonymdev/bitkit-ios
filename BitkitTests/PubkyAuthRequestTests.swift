@testable import Bitkit
import XCTest

/// Tests for PubkyAuthRequest capability parsing and permission display.
final class PubkyAuthRequestTests: XCTestCase {
    // MARK: - parseCapabilities

    func testParseCapabilitiesSingleEntry() {
        let permissions = PubkyAuthRequest.parseCapabilities("/pub/pubky.app/:rw")

        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions[0].path, "/pub/pubky.app/")
        XCTAssertEqual(permissions[0].accessLevel, "rw")
    }

    func testParseCapabilitiesMultipleEntries() {
        let permissions = PubkyAuthRequest.parseCapabilities("/pub/pubky.app/:rw,/pub/paykit/v0/:r")

        XCTAssertEqual(permissions.count, 2)
        XCTAssertEqual(permissions[0].path, "/pub/pubky.app/")
        XCTAssertEqual(permissions[0].accessLevel, "rw")
        XCTAssertEqual(permissions[1].path, "/pub/paykit/v0/")
        XCTAssertEqual(permissions[1].accessLevel, "r")
    }

    func testParseCapabilitiesEmptyString() {
        let permissions = PubkyAuthRequest.parseCapabilities("")

        XCTAssertTrue(permissions.isEmpty)
    }

    func testParseCapabilitiesMalformedNoColon() {
        // No colon separator → should be filtered out
        let permissions = PubkyAuthRequest.parseCapabilities("/pub/pubky.app/rw")

        XCTAssertTrue(permissions.isEmpty)
    }

    func testParseCapabilitiesWhitespace() {
        let permissions = PubkyAuthRequest.parseCapabilities(" /pub/pubky.app/:rw , /pub/paykit/v0/:r ")

        XCTAssertEqual(permissions.count, 2)
        XCTAssertEqual(permissions[0].path, "/pub/pubky.app/")
        XCTAssertEqual(permissions[1].path, "/pub/paykit/v0/")
    }

    func testParseCapabilitiesEmptyPath() {
        // Colon at start → empty path should be filtered
        let permissions = PubkyAuthRequest.parseCapabilities(":rw")

        XCTAssertTrue(permissions.isEmpty)
    }

    func testParseCapabilitiesEmptyAccess() {
        // Trailing colon → empty access should be filtered
        let permissions = PubkyAuthRequest.parseCapabilities("/pub/pubky.app/:")

        XCTAssertTrue(permissions.isEmpty)
    }

    func testParseCapabilitiesMultipleColons() {
        // Path contains a colon — lastIndex should split at the final one
        let permissions = PubkyAuthRequest.parseCapabilities("/pub/some:thing/:rw")

        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions[0].path, "/pub/some:thing/")
        XCTAssertEqual(permissions[0].accessLevel, "rw")
    }

    // MARK: - extractServiceName

    func testExtractServiceNameStandard() {
        XCTAssertEqual(PubkyAuthRequest.extractServiceName("/pub/pubky.app/"), "pubky.app")
    }

    func testExtractServiceNameDeepPath() {
        // Should take the component at index 1, ignoring deeper segments
        XCTAssertEqual(PubkyAuthRequest.extractServiceName("/pub/paykit/v0/"), "paykit")
    }

    func testExtractServiceNameSingleComponent() {
        // Only "pub" after trimming — fewer than 2 components
        XCTAssertNil(PubkyAuthRequest.extractServiceName("/pub/"))
    }

    func testExtractServiceNameEmpty() {
        XCTAssertNil(PubkyAuthRequest.extractServiceName(""))
    }

    func testExtractServiceNameRootSlash() {
        XCTAssertNil(PubkyAuthRequest.extractServiceName("/"))
    }

    func testExtractServiceNameNoLeadingSlash() {
        // Trim handles missing leading slash
        XCTAssertEqual(PubkyAuthRequest.extractServiceName("pub/pubky.app/"), "pubky.app")
    }

    // MARK: - PubkyAuthPermission displayAccess

    func testDisplayAccessReadWrite() {
        let permission = PubkyAuthPermission(path: "/test", accessLevel: "rw")
        XCTAssertEqual(permission.displayAccess, "READ, WRITE")
    }

    func testDisplayAccessReadOnly() {
        let permission = PubkyAuthPermission(path: "/test", accessLevel: "r")
        XCTAssertEqual(permission.displayAccess, "READ")
    }

    func testDisplayAccessWriteOnly() {
        let permission = PubkyAuthPermission(path: "/test", accessLevel: "w")
        XCTAssertEqual(permission.displayAccess, "WRITE")
    }

    func testDisplayAccessUnknownFlags() {
        let permission = PubkyAuthPermission(path: "/test", accessLevel: "x")
        XCTAssertEqual(permission.displayAccess, "")
    }

    func testDisplayAccessEmpty() {
        let permission = PubkyAuthPermission(path: "/test", accessLevel: "")
        XCTAssertEqual(permission.displayAccess, "")
    }
}
