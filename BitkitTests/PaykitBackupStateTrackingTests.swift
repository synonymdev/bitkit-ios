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
}
