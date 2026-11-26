@testable import Bitkit
import XCTest

final class ProfileRemovalStoreTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("pending.json")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    func testPendingSurvivesReconstructionAndOnlyExactAttemptCompletes() throws {
        let id = UUID()
        let first = ProfileRemovalStore(url: url)
        try first.begin(id: id)
        let reopened = ProfileRemovalStore(url: url)
        XCTAssertEqual(try reopened.pending()?.id, id)
        XCTAssertThrowsError(try reopened.requireNoPending())
        XCTAssertThrowsError(try reopened.begin(id: UUID()))
        XCTAssertThrowsError(try reopened.complete(id: UUID()))
        try reopened.complete(id: id)
        XCTAssertNil(try ProfileRemovalStore(url: url).pending())
    }

    func testGenerationRejectsWorkAcrossEntirePendingInterval() throws {
        let store = ProfileRemovalStore(url: url)
        let generation = try store.requireNoPending()
        let id = UUID()
        try store.begin(id: id)
        try store.complete(id: id)
        XCTAssertThrowsError(try store.validate(generation: generation))
        XCTAssertNoThrow(try store.validate(generation: store.requireNoPending()))
    }

    func testMalformedOrNewerDataFailsClosedWithoutOverwritingIt() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values = try [Data("invalid".utf8), JSONEncoder().encode(ProfileRemovalStore.Pending(version: 2, id: UUID(), scope: .profile))]
        for bytes in values {
            try bytes.write(to: url)
            let store = ProfileRemovalStore(url: url)
            XCTAssertThrowsError(try store.pending())
            XCTAssertThrowsError(try store.requireNoPending())
            XCTAssertThrowsError(try store.begin(id: UUID()))
            XCTAssertThrowsError(try store.complete(id: UUID()))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testExplicitRecoveryAssignsExactUUIDOnlyToKnownMalformedRecord() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(#"{"version":1,"scope":"walletWipe","id":"damaged"}"#.utf8)
        try bytes.write(to: url)
        let store = ProfileRemovalStore(url: url)
        XCTAssertThrowsError(try store.pending())
        try store.recoverMalformedRecord()
        let record = try XCTUnwrap(store.pending())
        XCTAssertEqual(record.scope, .walletWipe)
        XCTAssertEqual(try ProfileRemovalStore(url: url).pending(), record)
        XCTAssertThrowsError(try store.complete(id: UUID(), scope: .walletWipe))
        try store.recoverMalformedRecord()
        XCTAssertEqual(try store.pending(), record)
        try store.complete(id: record.id, scope: .walletWipe)
        let future = Data(#"{"version":2,"scope":"profile","id":"damaged"}"#.utf8)
        try future.write(to: url)
        XCTAssertThrowsError(try store.recoverMalformedRecord())
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testFailedWriteCannotAuthorizeDestructiveWork() throws {
        let store = ProfileRemovalStore(url: url, write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try store.begin(id: UUID()))
        XCTAssertNil(try store.pending())
    }

    func testFailedCompletionRetainsPendingForLocalRecovery() throws {
        let id = UUID()
        let store = ProfileRemovalStore(url: url, remove: { _ in throw CocoaError(.fileWriteNoPermission) })
        try store.begin(id: id)
        XCTAssertThrowsError(try store.complete(id: id))
        XCTAssertEqual(try ProfileRemovalStore(url: url).pending()?.id, id)
    }

    func testWalletWipeCannotBeDowngradedOrCompletedAsProfileCleanup() throws {
        let id = UUID()
        let store = ProfileRemovalStore(url: url)
        try store.begin(id: id)
        try store.begin(id: id, scope: .walletWipe)
        XCTAssertThrowsError(try store.begin(id: id))
        XCTAssertThrowsError(try store.complete(id: id))
        XCTAssertEqual(try store.pending()?.scope, .walletWipe)
        try store.complete(id: id, scope: .walletWipe)
        XCTAssertNil(try store.pending())
    }
}
