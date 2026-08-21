@testable import Bitkit
import XCTest

/// Covers the change detection that decides whether a restored envelope is a legacy one worth
/// rewriting to VSS. The real migrations come from bitkit-core; these stub them.
final class BackupFieldMigrationTests: XCTestCase {
    private struct StubError: Error {}

    private func envelope(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ data: Data) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    private func records(_ data: Data, field: String) -> [[String: Any]] {
        decode(data)[field] as! [[String: Any]]
    }

    private let legacy: [String: Any] = [
        "version": 1,
        "createdAt": 1_700_000_000_000,
        "activities": [["id": "a1", "txId": "tx1"]],
    ]

    // MARK: - Unchanged envelopes

    func testIdentityMigrationReportsNoChangeAndReturnsInputVerbatim() {
        let input = envelope(legacy)

        let result = BackupFieldMigration.apply(input, fieldMigrations: ["activities": { $0 }])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, input)
    }

    /// Core's serializer may reorder object keys without changing a value. Comparing raw strings
    /// would read that as a migration and re-upload the envelope on every restore.
    func testReorderedKeysAreNotTreatedAsAChange() {
        let input = envelope(["version": 1, "activities": [["id": "a1", "txId": "tx1"]]])

        let result = BackupFieldMigration.apply(input, fieldMigrations: [
            "activities": { _ in #"[{"txId":"tx1","id":"a1"}]"# },
        ])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, input)
    }

    func testAbsentFieldIsSkipped() {
        let input = envelope(legacy)

        let result = BackupFieldMigration.apply(input, fieldMigrations: [
            "activityTags": { json in
                XCTFail("migration ran for a field the envelope does not carry")
                return json
            },
        ])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, input)
    }

    func testNonArrayFieldIsSkipped() {
        let input = envelope(["activities": "not-an-array"])

        let result = BackupFieldMigration.apply(input, fieldMigrations: [
            "activities": { json in
                XCTFail("migration ran for a field that is not an array")
                return json
            },
        ])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, input)
    }

    func testNonObjectEnvelopeIsReturnedUnchanged() throws {
        let bareArray = try JSONSerialization.data(withJSONObject: [1, 2, 3])
        let garbage = Data("not json".utf8)

        for input in [bareArray, garbage] {
            let result = BackupFieldMigration.apply(input, fieldMigrations: ["activities": { $0 }])

            XCTAssertFalse(result.changed)
            XCTAssertEqual(result.data, input)
        }
    }

    // MARK: - Migrated envelopes

    func testAddedWalletIdIsReportedAndSpliced() {
        let result = BackupFieldMigration.apply(envelope(legacy), fieldMigrations: [
            "activities": { _ in #"[{"id":"a1","txId":"tx1","walletId":"bitkit"}]"# },
        ])

        XCTAssertTrue(result.changed)
        XCTAssertEqual(records(result.data, field: "activities").first?["walletId"] as? String, "bitkit")
    }

    func testSiblingKeysSurviveTheRoundTrip() {
        let result = BackupFieldMigration.apply(envelope(legacy), fieldMigrations: [
            "activities": { _ in #"[{"id":"a1","walletId":"bitkit"}]"# },
        ])

        XCTAssertTrue(result.changed)
        XCTAssertEqual(decode(result.data)["version"] as? Int, 1)
        XCTAssertEqual(decode(result.data)["createdAt"] as? Int, 1_700_000_000_000)
    }

    /// Records are compared positionally, so a reordering migration reports a change it did not
    /// make. That costs one wasted upload, which is the safe direction to be wrong in.
    func testReorderedRecordsAreTreatedAsAChange() {
        let input = envelope(["activities": [["id": "a1"], ["id": "a2"]]])

        let result = BackupFieldMigration.apply(input, fieldMigrations: [
            "activities": { _ in #"[{"id":"a2"},{"id":"a1"}]"# },
        ])

        XCTAssertTrue(result.changed)
    }

    // MARK: - Failing migrations

    func testThrowingMigrationKeepsOriginalAndDoesNotReportAChange() {
        let input = envelope(legacy)

        let result = BackupFieldMigration.apply(input, fieldMigrations: [
            "activities": { _ in throw StubError() },
        ])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, input)
    }

    func testOneFailingMigrationDoesNotBlockTheOther() {
        let input = envelope([
            "activities": [["id": "a1"]],
            "activityTags": [["activityId": "a1", "tags": ["cold"]]],
        ])

        let result = BackupFieldMigration.apply(input, fieldMigrations: [
            "activities": { _ in throw StubError() },
            "activityTags": { _ in #"[{"activityId":"a1","tags":["cold"],"walletId":"bitkit"}]"# },
        ])

        XCTAssertTrue(result.changed)
        XCTAssertNil(records(result.data, field: "activities").first?["walletId"])
        XCTAssertEqual(records(result.data, field: "activityTags").first?["walletId"] as? String, "bitkit")
    }

    func testUndecodableMigrationOutputKeepsOriginal() {
        let input = envelope(legacy)

        let result = BackupFieldMigration.apply(input, fieldMigrations: [
            "activities": { _ in "not json" },
        ])

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.data, input)
    }
}
