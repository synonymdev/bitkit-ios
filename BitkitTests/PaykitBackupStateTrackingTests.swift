@testable import Bitkit
import XCTest

@MainActor
final class PaykitBackupStateTrackingTests: XCTestCase {
    private enum Failure: Error, Equatable { case revision, admission, operation }

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

    func testRejectedAdmissionDoesNotRunOrInvalidateBackup() async {
        var reads = 0
        do {
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: { reads += 1; return "before" },
                onSnapshot: { _ in XCTFail("Admission failure must not replace the backup snapshot") },
                onChange: { XCTFail("Admission failure must not request a backup") },
                beforeOperation: { throw Failure.admission },
                operation: { XCTFail("The write must not run after admission failed") }
            )
            XCTFail("Expected admission failure")
        } catch {
            XCTAssertEqual(error as? Failure, .admission)
        }
        XCTAssertEqual(reads, 1)
    }

    func testCancellationAfterMutationStillRequestsBackup() async {
        for throwsCancellation in [false, true] {
            var revision = "before"
            var snapshot: PaykitSdkService.BackupStateSnapshot? = .init(stateRevision: "state", backupRevision: revision)
            var reads = 0
            var changes = 0
            let task = Task {
                try await PaykitSdkService.withBackupStateRevisionTracking(
                    readRevision: { reads += 1; return revision },
                    readStateRevision: { "state" },
                    readObservedSnapshot: { .init(stateRevision: "state", backupRevision: revision) },
                    cachedSnapshot: snapshot,
                    onSnapshot: { snapshot = $0 },
                    onChange: { changes += 1 },
                    operation: {
                        revision = "after"
                        withUnsafeCurrentTask { $0?.cancel() }
                        if throwsCancellation { try Task.checkCancellation() }
                    }
                )
            }
            do {
                try await task.value
                XCTAssertFalse(throwsCancellation)
            } catch {
                XCTAssertTrue(throwsCancellation)
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(revision, "after")
            XCTAssertEqual(changes, 1)
            XCTAssertEqual(reads, 0)
            XCTAssertNil(snapshot)
        }
    }

    func testUnchangedOperationsReuseBackupFingerprintWithoutRemoteReads() async throws {
        var snapshot: PaykitSdkService.BackupStateSnapshot?
        var state = "initial"
        var reads = 0
        var changes = 0
        for index in 0 ..< 3 {
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: { reads += 1; return "content" },
                readStateRevision: { state },
                readObservedSnapshot: { .init(stateRevision: state, backupRevision: "content") },
                cachedSnapshot: snapshot,
                onSnapshot: { snapshot = $0 },
                onChange: { changes += 1 },
                operation: { state = "lease-\(index)" }
            )
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(snapshot?.stateRevision, "lease-2")
        XCTAssertEqual(snapshot?.backupRevision, "content")
    }

    func testObservedRevisionsCompareWithCachedBackupContent() async throws {
        for (observedState, finalContent, expectedReads, expectedChanges) in [
            ("current", "content", 0, 0),
            ("current", "changed", 0, 1),
            ("unavailable", "changed", 1, 1),
            ("stale", "changed", 1, 1),
            ("unreadable", "changed", 1, 1),
        ] {
            var reads = 0
            var changes = 0
            var snapshot: PaykitSdkService.BackupStateSnapshot?
            try await PaykitSdkService.withBackupStateRevisionTracking(
                readRevision: { reads += 1; return finalContent },
                readStateRevision: { "current" },
                readObservedSnapshot: {
                    if observedState == "unavailable" { return nil }
                    if observedState == "unreadable" { throw Failure.revision }
                    return .init(stateRevision: observedState, backupRevision: finalContent)
                },
                cachedSnapshot: .init(stateRevision: observedState == "current" ? "previous" : "current", backupRevision: "content"),
                onSnapshot: { snapshot = $0 },
                onChange: { changes += 1 },
                operation: {}
            )
            XCTAssertEqual(reads, expectedReads)
            XCTAssertEqual(changes, expectedChanges)
            XCTAssertEqual(snapshot?.stateRevision, "current")
            XCTAssertEqual(snapshot?.backupRevision, finalContent)
        }
    }

    func testFailedWriteInvalidatesBackupWithoutAnotherRemoteRead() async {
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
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(snapshot)
    }
}
