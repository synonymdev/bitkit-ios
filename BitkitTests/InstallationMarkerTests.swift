@testable import Bitkit
import XCTest

final class InstallationMarkerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Clean up before each test
        try? InstallationMarker.delete()
    }

    override func tearDown() {
        // Clean up after each test
        try? InstallationMarker.delete()
        super.tearDown()
    }

    func testMarkerDoesNotExistInitially() {
        // After cleanup in setUp, marker should not exist
        XCTAssertFalse(InstallationMarker.exists())
    }

    func testCreateMarker() throws {
        // Initially should not exist
        XCTAssertFalse(InstallationMarker.exists())

        // Create the marker
        try InstallationMarker.create()

        // Now should exist
        XCTAssertTrue(InstallationMarker.exists())

        // Verify file actually exists at the expected path
        XCTAssertTrue(FileManager.default.fileExists(atPath: InstallationMarker.markerPath.path))
    }

    func testDeleteMarker() throws {
        // Create the marker first
        try InstallationMarker.create()
        XCTAssertTrue(InstallationMarker.exists())

        // Delete it
        try InstallationMarker.delete()

        // Should no longer exist
        XCTAssertFalse(InstallationMarker.exists())
        XCTAssertFalse(FileManager.default.fileExists(atPath: InstallationMarker.markerPath.path))
    }

    func testDeleteNonExistentMarkerDoesNotThrow() {
        // Ensure marker doesn't exist
        XCTAssertFalse(InstallationMarker.exists())

        // Deleting non-existent marker should not throw
        XCTAssertNoThrow(try InstallationMarker.delete())
    }

    func testMarkerPathUsesSandboxDocuments() {
        // Get the expected sandbox Documents directory
        let sandboxDocuments = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Verify marker path is within sandbox Documents, not app group
        XCTAssertTrue(InstallationMarker.markerPath.path.hasPrefix(sandboxDocuments.path))

        // Verify it's NOT using the app group container
        // App group would contain "group.bitkit" in the path
        XCTAssertFalse(InstallationMarker.markerPath.path.contains("group.bitkit"))
    }

    func testCreateMarkerIsIdempotent() throws {
        // Create the marker
        try InstallationMarker.create()
        XCTAssertTrue(InstallationMarker.exists())

        // Creating again should overwrite without error
        // (the file content is a new UUID each time, but that's fine)
        try InstallationMarker.create()
        XCTAssertTrue(InstallationMarker.exists())
    }

    func testMarkerPersistsAcrossChecks() throws {
        // Create the marker
        try InstallationMarker.create()

        // Multiple checks should all return true
        XCTAssertTrue(InstallationMarker.exists())
        XCTAssertTrue(InstallationMarker.exists())
        XCTAssertTrue(InstallationMarker.exists())
    }
}
