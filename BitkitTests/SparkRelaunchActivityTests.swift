@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

/// A send over Spark that was still in flight when the app was killed, recorded on the next launch.
@MainActor
final class SparkRelaunchActivityTests: XCTestCase {
    func testTheFirstActivitySyncOfALaunchWaitsForSparksOwnSync() async throws {
        var calls: [String] = []

        _ = try await SparkManager.startConnected(
            activitiesSynced: false,
            refresh: { calls.append("refresh") },
            syncWallet: { calls.append("syncWallet") },
            syncActivities: { calls.append("syncActivities") }
        )

        XCTAssertEqual(calls, ["refresh", "syncWallet", "syncActivities"], "The activities were read before Spark listed the send")
    }

    func testAFailedSparkSyncStillRecordsTheActivitiesItHas() async throws {
        var synced = false

        _ = try await SparkManager.startConnected(
            activitiesSynced: false,
            refresh: {},
            syncWallet: { throw URLError(.timedOut) },
            syncActivities: { synced = true }
        )

        XCTAssertTrue(synced)
    }

    func testContactsRememberedAndForgottenAtOnceAreNotLost() throws {
        let suite = "SparkRelaunchActivityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let contacts = SentPaymentContacts(defaults: defaults)

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            contacts.remember("pk:\(index)", forPaymentHash: "hash\(index)")
            contacts.forget(paymentHash: "gone\(index)")
        }

        let lost = (0 ..< 500).filter { contacts.contact(forPaymentHash: "hash\($0)") == nil }
        XCTAssertEqual(lost, [], "Concurrent updates dropped remembered contacts")
    }

    func testASendRecordedAfterARelaunchKeepsTheContactItPaid() async throws {
        let suite = "SparkRelaunchActivityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = ActivityService.sentPaymentContacts
        ActivityService.sentPaymentContacts = SentPaymentContacts(defaults: defaults)
        defer { ActivityService.sentPaymentContacts = previous }
        // A fresh hash per run, as the activity store outlives a test run.
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "c4", count: 16)
        let contact = "pk:contact"
        ActivityService.sentPaymentContacts.remember(contact, forPaymentHash: hash)

        // The relaunch records the send from Spark's history; the send flow that would set its contact is gone.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(PaymentDetails(
            id: hash,
            kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
            amountMsat: 300_000, feePaidMsat: 1000, direction: .outbound, status: .succeeded, latestUpdateTimestamp: 100
        ))

        let activity = try await CoreService.shared.activity.getActivity(id: hash)
        guard case let .lightning(lightning)? = activity else { return XCTFail("The send wasn't recorded") }
        XCTAssertEqual(lightning.contact, contact, "The relaunch recorded the send without its contact")
        XCTAssertNil(ActivityService.sentPaymentContacts.contact(forPaymentHash: hash), "The remembered contact outlived its activity")
    }

    func testASendRecordedPendingBeforeTheKillGetsItsContactWhenItSettles() async throws {
        let suite = "SparkRelaunchActivityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = ActivityService.sentPaymentContacts
        ActivityService.sentPaymentContacts = SentPaymentContacts(defaults: defaults)
        defer { ActivityService.sentPaymentContacts = previous }
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "d5", count: 16)
        func send(_ status: LDKNode.PaymentStatus, at timestamp: UInt64) -> PaymentDetails {
            PaymentDetails(
                id: hash,
                kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
                amountMsat: 300_000, feePaidMsat: 1000, direction: .outbound, status: status, latestUpdateTimestamp: timestamp
            )
        }
        // Spark recorded the send as pending before the app was killed, with no contact yet.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(send(.pending, at: 100))
        ActivityService.sentPaymentContacts.remember("pk:contact", forPaymentHash: hash)

        try await CoreService.shared.activity.recordChannelFreeRailPayment(send(.succeeded, at: 200))

        let activity = try await CoreService.shared.activity.getActivity(id: hash)
        guard case let .lightning(lightning)? = activity else { return XCTFail("The send wasn't recorded") }
        XCTAssertEqual(lightning.contact, "pk:contact")
    }
}
