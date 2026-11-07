@testable import Bitkit
import XCTest

final class ProfileRemovalReservationTests: XCTestCase {
    private let key = "privatePaykitAddressReservations"

    private func defaults() throws -> UserDefaults {
        let suite = "ProfileRemovalReservations.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRemovalClearsAttributionAndRetainsReservedIndexesAndRestoredCeilings() async throws {
        let defaults = try defaults()
        let original: [String: Any] = [
            "version": 1,
            "reservedReceiveIndexesByAddressType": ["nativeSegwit": [3, 7]],
            "contactAssignments": ["old-owner": ["addressType": "nativeSegwit", "receiveIndex": 7]],
            "contactAssignmentHistory": ["old-owner": [["addressType": "nativeSegwit", "receiveIndex": 3]]],
            "restoredReservedReceiveIndexCeilingsByAddressType": ["taproot": 12],
        ]
        try defaults.set(JSONSerialization.data(withJSONObject: original), forKey: key)
        let store = PrivatePaykitAddressReservationStore(defaults: defaults)
        try await store.clearContactAssignmentsForRemoval()
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        XCTAssertEqual(result["contactAssignments"] as? [String: String], [:])
        XCTAssertEqual(result["contactAssignmentHistory"] as? [String: String], [:])
        XCTAssertEqual(Set((result["reservedReceiveIndexesByAddressType"] as? [String: [Int]])?["nativeSegwit"] ?? []), [3, 7])
        XCTAssertEqual(result["restoredReservedReceiveIndexCeilingsByAddressType"] as? [String: Int], ["taproot": 12])
        let snapshot = await store.backupSnapshot()
        XCTAssertEqual(snapshot, ["nativeSegwit": 7, "taproot": 12])
    }

    func testRemovalRejectsUnreadableLedgerWithoutReplacingItWithEmptyState() async throws {
        let defaults = try defaults()
        for original in [Data("invalid-ledger".utf8), Data("{\"version\":2}".utf8)] {
            defaults.set(original, forKey: key)
            let store = PrivatePaykitAddressReservationStore(defaults: defaults)
            do {
                try await store.clearContactAssignmentsForRemoval()
                XCTFail("Unreadable reservation exclusions must remain intact")
            } catch ProfileRemovalStore.StoreError.unavailable {}
            XCTAssertEqual(defaults.data(forKey: key), original)
        }
    }

    func testRemovalRejectsAStaleLoadedLedgerInsteadOfOverwritingNewerExclusions() async throws {
        let defaults = try defaults()
        let stale = PrivatePaykitAddressReservationStore(defaults: defaults)
        let replacement = PrivatePaykitAddressReservationStore(defaults: defaults)
        await replacement.restoreBackup(["taproot": 28])
        let original = defaults.data(forKey: key)
        do {
            try await stale.clearContactAssignmentsForRemoval()
            XCTFail("A stale owner cannot acknowledge cleanup of newer state")
        } catch ProfileRemovalStore.StoreError.unavailable {}
        XCTAssertEqual(defaults.data(forKey: key), original)
    }
}
