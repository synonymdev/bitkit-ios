@testable import Bitkit
import XCTest

/// Tests for PubkyAuthRequest capability parsing and permission display.
final class PubkyAuthRequestTests: XCTestCase {
    private let relay = "https%3A%2F%2Fhttprelay.pubky.app%2Finbox%2F"
    private let secret = "e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s"

    func testProtocolUrlRecognizesPubkyAuthSchemeCaseInsensitively() {
        XCTAssertTrue(PubkyAuthRequest.isProtocolURL("pubkyauth://signin?caps=/pub/bitkit.to/:rw"))
        XCTAssertTrue(PubkyAuthRequest.isProtocolURL("PUBKYAUTH://signin?caps=/pub/bitkit.to/:rw"))
        XCTAssertTrue(PubkyAuthRequest.isProtocolURL("  pubkyauth://signin?caps=/pub/bitkit.to/:rw\n"))
        XCTAssertFalse(PubkyAuthRequest.isProtocolURL("lightning:lnbc1example"))
    }

    func testProtocolUrlNormalizesBitkitSpecificSetupHandoff() throws {
        let url = "bitkit://pubky-auth/setup?caps=\(PubkyAuthClaim.watchOnlyAccountCapabilities)" +
            "&relay=\(relay)&secret=\(secret)&x-bitkit-claim=watch-only-account-v1"

        XCTAssertTrue(PubkyAuthRequest.isProtocolURL(url))

        let request = try PubkyAuthRequest.parse(url: url)

        XCTAssertTrue(request.rawUrl.hasPrefix("pubkyauth://signin?"))
        XCTAssertEqual(request.bitkitClaim, .watchOnlyAccountV1)
        XCTAssertEqual(request.capabilities, PubkyAuthClaim.watchOnlyAccountCapabilities)
    }

    func testProtocolUrlRejectsBitkitSpecificSetupHandoffWithoutClaimMarker() {
        let url = "bitkit://pubky-auth/setup?caps=\(PubkyAuthClaim.watchOnlyAccountCapabilities)" +
            "&relay=\(relay)&secret=\(secret)"

        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url)) {
            XCTAssertEqual($0 as? PubkyAuthRequestError, .missingBitkitClaim)
        }
    }

    func testProtocolUrlRejectsGenericBitkitSetupHandoffWithoutClaimMarker() {
        let url = "bitkit://pubky-auth/setup?caps=/pub/locks.app/:rw&relay=\(relay)&secret=\(secret)"

        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url)) {
            XCTAssertEqual($0 as? PubkyAuthRequestError, .missingBitkitClaim)
        }
    }

    func testProtocolUrlDoesNotTreatPubkyRingCallbackAsSetupHandoff() {
        let url = "bitkit://pubky-auth/success?nonce=123"

        XCTAssertFalse(PubkyAuthRequest.isProtocolURL(url))
        XCTAssertEqual(PubkyAuthRequest.normalizedProtocolURL(url), url)
    }

    func testProtocolUrlRejectsSetupHandoffWithUserInfoOrPort() {
        let query = "caps=<approve>&relay=https%3A%2F%2Fx&secret=first"
        let urls = [
            "bitkit://user@pubky-auth/setup?\(query)",
            "bitkit://pubky-auth:123/setup?\(query)",
        ]

        for url in urls {
            XCTAssertFalse(PubkyAuthRequest.isProtocolURL(url))
            XCTAssertEqual(PubkyAuthRequest.normalizedProtocolURL(url), url)
        }
    }

    func testProtocolUrlRejectsFragment() {
        let query = "caps=a%2Fb&relay=https%3A%2F%2Fx&secret=first&secret=second"
        let url = "bitkit://pubky-auth/setup?\(query)#ignored"

        XCTAssertFalse(PubkyAuthRequest.isProtocolURL(url))
        XCTAssertEqual(PubkyAuthRequest.normalizedProtocolURL(url), url)
        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url))
    }

    func testProtocolUrlDoesNotReserializeRawOrEncodedQueryBytes() {
        let query = "caps=<approve>%23encoded&relay=https%3A%2F%2Fx&secret=first&secret=second"

        XCTAssertEqual(
            PubkyAuthRequest.normalizedProtocolURL("bitkit://pubky-auth/setup?\(query)"),
            "pubkyauth://signin?\(query)"
        )
    }

    func testProtocolUrlRejectsBitkitSetupHandoffWithoutQuery() {
        let url = "bitkit://pubky-auth/setup"

        XCTAssertFalse(PubkyAuthRequest.isProtocolURL(url))
        XCTAssertEqual(PubkyAuthRequest.normalizedProtocolURL(url), url)
        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url))
    }

    func testProtocolUrlRejectsEmptyOrDuplicateQueryDelimiter() {
        let urls = [
            "bitkit://pubky-auth/setup?",
            "bitkit://pubky-auth/setup??secret=first",
        ]

        for url in urls {
            XCTAssertFalse(PubkyAuthRequest.isProtocolURL(url))
            XCTAssertEqual(PubkyAuthRequest.normalizedProtocolURL(url), url)
            XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url))
        }
    }

    func testProtocolUrlDoesNotTreatFragmentQuestionMarkAsQuery() {
        let url = "bitkit://pubky-auth/setup#ignored?caps=<approve>"

        XCTAssertFalse(PubkyAuthRequest.isProtocolURL(url))
        XCTAssertEqual(PubkyAuthRequest.normalizedProtocolURL(url), url)
        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url))
    }

    func testParseUrlPreservesRequestedCapabilities() throws {
        let capabilities = "/pub/bitkit.to/:rw"
        let url = "pubkyauth://signin?caps=\(capabilities)&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s"

        let request = try PubkyAuthRequest.parse(url: url)

        XCTAssertEqual(request.capabilities, capabilities)
        XCTAssertEqual(request.permissions.count, 1)
        XCTAssertEqual(request.permissions[0].path, "/pub/bitkit.to/")
    }

    func testParseUrlDeduplicatesServiceNameAcrossPublicAndPrivateCapabilities() throws {
        let capabilities = "/pub/locks.app/:rw,/priv/locks.app/:rw"

        let request = try PubkyAuthRequest.parse(url: authUrl(capabilities: capabilities))

        XCTAssertEqual(request.permissions.map(\.path), ["/pub/locks.app/", "/priv/locks.app/"])
        XCTAssertEqual(request.serviceNames, ["locks.app"])
    }

    func testParseUrlDeduplicatesServiceNamesAcrossMultiplePathsInFirstSeenOrder() throws {
        let capabilities = "/pub/locks.app/posts/:r,/pub/example.app/:r,/priv/locks.app/settings/:w,/priv/example.app/cache/:r"

        let request = try PubkyAuthRequest.parse(url: authUrl(capabilities: capabilities))

        XCTAssertEqual(request.permissions.count, 4)
        XCTAssertEqual(request.serviceNames, ["locks.app", "example.app"])
    }

    func testParseUrlRecognizesWatchOnlyAccountClaim() throws {
        let capabilities = PubkyAuthClaim.watchOnlyAccountCapabilities
        let url = authUrl(capabilities: capabilities, claimValues: [PubkyAuthClaim.watchOnlyAccountV1.rawValue])

        let request = try PubkyAuthRequest.parse(url: url)

        XCTAssertEqual(request.bitkitClaim, .watchOnlyAccountV1)
    }

    func testParseUrlRecognizesWatchOnlyAccountClaimWithReorderedCapabilities() throws {
        let capabilities = PubkyAuthClaim.watchOnlyAccountCapabilities
            .split(separator: ",")
            .reversed()
            .joined(separator: ",")
        let url = authUrl(capabilities: capabilities, claimValues: [PubkyAuthClaim.watchOnlyAccountV1.rawValue])

        let request = try PubkyAuthRequest.parse(url: url)

        XCTAssertEqual(request.bitkitClaim, .watchOnlyAccountV1)
    }

    func testParseUrlRecognizesWatchOnlyAccountClaimWithCapabilityWhitespace() throws {
        let capabilities = PubkyAuthClaim.watchOnlyAccountCapabilities.replacingOccurrences(of: ",", with: " , ")
        let url = authUrl(capabilities: capabilities, claimValues: [PubkyAuthClaim.watchOnlyAccountV1.rawValue])

        let request = try PubkyAuthRequest.parse(url: url)

        XCTAssertEqual(request.bitkitClaim, .watchOnlyAccountV1)
    }

    func testParseUrlWithoutBitkitClaimPreservesNormalAuth() throws {
        let request = try PubkyAuthRequest.parse(url: authUrl(capabilities: "/pub/bitkit.to/:rw"))

        XCTAssertNil(request.bitkitClaim)
    }

    func testParseUrlRejectsWatchOnlyCapabilityWithoutClaim() {
        let url = authUrl(capabilities: PubkyAuthClaim.watchOnlyAccountCapabilities)

        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url)) {
            XCTAssertEqual($0 as? PubkyAuthRequestError, .missingBitkitClaim)
        }
    }

    func testParseUrlRejectsDuplicateBitkitClaim() {
        let url = authUrl(
            capabilities: PubkyAuthClaim.watchOnlyAccountCapabilities,
            claimValues: [PubkyAuthClaim.watchOnlyAccountV1.rawValue, PubkyAuthClaim.watchOnlyAccountV1.rawValue]
        )

        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url)) {
            XCTAssertEqual($0 as? PubkyAuthRequestError, .duplicateBitkitClaim)
        }
    }

    func testParseUrlRejectsUnknownBitkitClaim() {
        let url = authUrl(capabilities: PubkyAuthClaim.watchOnlyAccountCapabilities, claimValues: ["unknown-v1"])

        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url)) {
            XCTAssertEqual($0 as? PubkyAuthRequestError, .unsupportedBitkitClaim("unknown-v1"))
        }
    }

    func testParseUrlRejectsWatchOnlyClaimWithOtherCapabilities() {
        let url = authUrl(capabilities: "/pub/paykit/v0/:rw", claimValues: [PubkyAuthClaim.watchOnlyAccountV1.rawValue])

        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url)) {
            XCTAssertEqual($0 as? PubkyAuthRequestError, .invalidBitkitClaimCapabilities)
        }
    }

    func testParseUrlRejectsWatchOnlyClaimWithoutPrivateCapability() {
        let capabilities = "/pub/paykit/v0/bitkit/server/:rw"
        let url = authUrl(capabilities: capabilities, claimValues: [PubkyAuthClaim.watchOnlyAccountV1.rawValue])

        XCTAssertThrowsError(try PubkyAuthRequest.parse(url: url)) {
            XCTAssertEqual($0 as? PubkyAuthRequestError, .invalidBitkitClaimCapabilities)
        }
    }

    func testWatchOnlyCapabilityMatcherRejectsEmptyCapability() {
        let capabilities = "\(PubkyAuthClaim.watchOnlyAccountCapabilities),"

        XCTAssertFalse(PubkyAuthClaim.matchesWatchOnlyAccountCapabilities(capabilities))
    }

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

    // MARK: - PubkyAuthPermission display

    func testDisplayPathRemovesCapabilitySeparator() {
        let permission = PubkyAuthPermission(path: "/pub/paykit/v0/bitkit/server/", accessLevel: "rw")
        XCTAssertEqual(permission.displayPath, "/pub/paykit/v0/bitkit/server")
    }

    func testDisplayPathPreservesRoot() {
        let permission = PubkyAuthPermission(path: "/", accessLevel: "r")
        XCTAssertEqual(permission.displayPath, "/")
    }

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

    private func authUrl(capabilities: String, claimValues: [String] = []) -> String {
        let claims = claimValues
            .map { "&\(PubkyAuthClaim.queryParameter)=\($0)" }
            .joined()
        return "pubkyauth://signin?caps=\(capabilities)&relay=\(relay)&secret=\(secret)\(claims)"
    }
}
