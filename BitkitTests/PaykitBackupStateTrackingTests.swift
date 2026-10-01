@testable import Bitkit
import XCTest

@MainActor
final class PaykitBackupStateTrackingTests: XCTestCase {
    private enum Failure: Error, Equatable { case revision, operation }

    func testBackupDecisionUsesContentAndTreatsUnreadableRevisionsConservatively() async throws {
        let cases: [(String?, String?, Int)] = [
            ("same", "same", 0),
            ("before", "after", 1),
            (nil, "after", 1),
            ("before", nil, 1),
        ]
        for (before, after, expectedChanges) in cases {
            var revisions = [before, after]
            var changes = 0
            let result = try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: {
                    guard let revision = revisions.removeFirst() else { throw Failure.revision }
                    return revision
                },
                onChange: { changes += 1 },
                operation: { "result" }
            )

            XCTAssertEqual(result, "result")
            XCTAssertEqual(changes, expectedChanges)
            XCTAssertTrue(revisions.isEmpty)
        }
    }

    func testPartialFailureMarksChangedStateAndPreservesOperationError() async {
        var revision = "before"
        var changes = 0
        do {
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: { revision },
                onChange: { changes += 1 },
                operation: {
                    revision = "after"
                    throw Failure.operation
                }
            )
            XCTFail("Expected operation failure")
        } catch {
            XCTAssertEqual(error as? Failure, .operation)
        }
        XCTAssertEqual(changes, 1)
    }

    func testCancellationAfterMutationStillRequestsBackup() async {
        var revision = "before"
        var changes = 0
        let task = Task {
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: {
                    try Task.checkCancellation()
                    return revision
                },
                onChange: { changes += 1 },
                operation: {
                    revision = "after"
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
            )
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(revision, "after")
        XCTAssertEqual(changes, 1)
    }

    func testUnchangedOperationsReuseBackupFingerprintWithoutRemoteReads() async throws {
        var snapshot: PaykitSdkService.BackupStateSnapshot?
        var reads = 0
        var changes = 0
        for _ in 0 ..< 3 {
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: { reads += 1; return "content" },
                readStateRevision: { "state" },
                cachedSnapshot: snapshot,
                onSnapshot: { snapshot = $0 },
                onChange: { changes += 1 },
                operation: {}
            )
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(snapshot?.backupRevision, "content")
    }

    func testStorageRevisionChangesStillCompareBackupContent() async throws {
        for (cachedState, finalContent, expectedReads, expectedChanges) in [
            ("before", "content", 1, 0),
            ("before", "changed", 1, 1),
            ("stale", "changed", 2, 1),
        ] {
            var state = "before"
            var content = "content"
            var reads = 0
            var changes = 0
            var snapshot: PaykitSdkService.BackupStateSnapshot?
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: { reads += 1; return content },
                readStateRevision: { state },
                cachedSnapshot: .init(stateRevision: cachedState, backupRevision: "content"),
                onSnapshot: { snapshot = $0 },
                onChange: { changes += 1 },
                operation: { state = "after"; content = finalContent }
            )
            XCTAssertEqual(reads, expectedReads)
            XCTAssertEqual(changes, expectedChanges)
            XCTAssertEqual(snapshot?.stateRevision, "after")
            XCTAssertEqual(snapshot?.backupRevision, finalContent)
        }
    }

    func testFailedWriteChecksBackupDespiteUnchangedLocalRevision() async {
        var snapshot: PaykitSdkService.BackupStateSnapshot? = .init(stateRevision: "state", backupRevision: "before")
        var reads = 0
        var changes = 0
        do {
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: { reads += 1; return "after" },
                readStateRevision: { "state" },
                cachedSnapshot: snapshot,
                onSnapshot: { snapshot = $0 },
                onChange: { changes += 1 },
                operation: { throw Failure.operation }
            )
            XCTFail("Expected unconfirmed write failure")
        } catch {
            XCTAssertEqual(error as? Failure, .operation)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(snapshot)
    }
}
