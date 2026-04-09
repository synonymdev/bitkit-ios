@testable import Bitkit
import XCTest

final class PubkyProfileManagerTests: XCTestCase {
    // MARK: - HomegateResponse Decoding

    private typealias HomegateResponse = PubkyProfileManager.HomegateResponse

    func testHomegateResponseDecodesCamelCase() throws {
        let json = """
        {"signupCode":"abc-123","homeserverPubky":"z6MkPubkyTestKey"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HomegateResponse.self, from: data)

        XCTAssertEqual(response.signupCode, "abc-123")
        XCTAssertEqual(response.homeserverPubky, "z6MkPubkyTestKey")
    }

    func testHomegateResponseRejectsIncompleteJson() {
        let json = """
        {"signupCode":"abc-123"}
        """
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(HomegateResponse.self, from: data))
    }

    func testHomegateResponseRejectsEmptyJson() {
        let json = "{}"
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(HomegateResponse.self, from: data))
    }

    func testHomegateResponseWithExtraFieldsDecodes() throws {
        let json = """
        {"signupCode":"abc","homeserverPubky":"z6Mk","extra":"ignored"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(HomegateResponse.self, from: data)

        XCTAssertEqual(response.signupCode, "abc")
        XCTAssertEqual(response.homeserverPubky, "z6Mk")
    }

    // MARK: - Image Resolution

    func testResolvedImageUrlPrefersNewImage() {
        let resolved = PubkyProfileManager.resolvedImageUrl(
            newImageUrl: "pubky://new-avatar",
            existingImageUrl: "pubky://existing-avatar"
        )

        XCTAssertEqual(resolved, "pubky://new-avatar")
    }

    func testResolvedImageUrlFallsBackToExistingImage() {
        let resolved = PubkyProfileManager.resolvedImageUrl(
            newImageUrl: nil,
            existingImageUrl: "pubky://existing-avatar"
        )

        XCTAssertEqual(resolved, "pubky://existing-avatar")
    }

    func testResolvedImageUrlAllowsMissingAvatar() {
        let resolved = PubkyProfileManager.resolvedImageUrl(
            newImageUrl: nil,
            existingImageUrl: nil
        )

        XCTAssertNil(resolved)
    }

    // MARK: - Remote Profile Resolution

    func testResolveRemoteProfilePrefersBitkitProfile() async throws {
        let bitkitProfile = makeProfile(publicKey: "pubky_test", name: "Bitkit")
        let pubkyFallback = makeProfile(publicKey: "pubky_test", name: "Pubky")

        let resolved = try await PubkyProfileManager.resolveRemoteProfile(
            publicKey: "pubky_test",
            fetchBitkitProfile: { _ in bitkitProfile },
            fetchPubkyProfile: { _ in
                XCTFail("Expected bitkit profile to win before pubky fallback")
                return pubkyFallback
            }
        )

        XCTAssertEqual(resolved.name, "Bitkit")
    }

    func testResolveRemoteProfileFallsBackToPubkyProfile() async throws {
        let fallbackProfile = makeProfile(publicKey: "pubky_test", name: "Pubky")

        let resolved = try await PubkyProfileManager.resolveRemoteProfile(
            publicKey: "pubky_test",
            fetchBitkitProfile: { _ in nil },
            fetchPubkyProfile: { _ in fallbackProfile }
        )

        XCTAssertEqual(resolved.name, "Pubky")
    }

    func testResolveRemoteProfileThrowsWhenNoRemoteProfileExists() async {
        await XCTAssertThrowsErrorAsync {
            try await PubkyProfileManager.resolveRemoteProfile(
                publicKey: "pubky_missing",
                fetchBitkitProfile: { _ in nil },
                fetchPubkyProfile: { _ in throw PubkyServiceError.profileNotFound }
            )
        }
    }

    // MARK: - Profile Link Input Model

    func testProfileLinkInputHasUniqueIds() {
        let link1 = ProfileLinkInput(label: "Website", url: "https://example.com")
        let link2 = ProfileLinkInput(label: "Website", url: "https://example.com")

        XCTAssertNotEqual(link1.id, link2.id)
    }

    private func makeProfile(publicKey: String, name: String) -> PubkyProfile {
        PubkyProfile(
            publicKey: publicKey,
            name: name,
            bio: "bio",
            imageUrl: nil,
            links: [],
            tags: [],
            status: nil
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
