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

    func testAFailedSparkRowKeepsItsDetailsAgainstAnOlderAttemptButTakesItsOwnAndLaterOnes() async throws {
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "e7", count: 16)
        func failed(sats: UInt64, feeSats: UInt64, at timestamp: UInt64) -> PaymentDetails {
            PaymentDetails(
                id: hash,
                kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
                amountMsat: sats * 1000, feePaidMsat: feeSats * 1000, direction: .outbound, status: .failed, latestUpdateTimestamp: timestamp
            )
        }
        func row() async throws -> LightningActivity? {
            guard case let .lightning(lightning)? = try await CoreService.shared.activity.getActivity(id: hash) else { return nil }
            return lightning
        }
        // An amountless invoice's retry, at another amount, failed and was recorded.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 500, feeSats: 0, at: 200))

        // A replay of the first attempt's failure leaves the retry's details.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 300, feeSats: 0, at: 100))
        var current = try await row()
        XCTAssertEqual(current?.value, 500, "an older attempt's failure replaced the retry's amount")

        // The retry's own fee correction still lands.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 500, feeSats: 3, at: 200))
        current = try await row()
        XCTAssertEqual(current?.fee, 3)

        // A later attempt's failure takes the row.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 700, feeSats: 0, at: 300))
        current = try await row()
        XCTAssertEqual(current?.value, 700)
    }

    func testAFailedSparkRowKeepsItsAttemptAgainstAnotherAttemptOfTheSameSecond() async throws {
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "e8", count: 16)
        func failed(sats: UInt64, feeSats: UInt64, at timestamp: UInt64) -> PaymentDetails {
            PaymentDetails(
                id: hash,
                kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
                amountMsat: sats * 1000, feePaidMsat: feeSats * 1000, direction: .outbound, status: .failed, latestUpdateTimestamp: timestamp
            )
        }
        func row() async throws -> LightningActivity? {
            guard case let .lightning(lightning)? = try await CoreService.shared.activity.getActivity(id: hash) else { return nil }
            return lightning
        }
        // A retry started in the same second as the first attempt, at another amount, failed and was recorded.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 500, feeSats: 0, at: 200), railPaymentId: "retry")

        // A replay of the first attempt's failure, dated the same second, leaves the retry's details.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 300, feeSats: 1, at: 200), railPaymentId: "first")
        var current = try await row()
        XCTAssertEqual(current?.value, 500, "another attempt of the same second replaced the retry's amount")
        XCTAssertEqual(current?.fee, 0, "another attempt of the same second replaced the retry's fee")

        // The retry's own fee correction still lands.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 500, feeSats: 3, at: 200), railPaymentId: "retry")
        current = try await row()
        XCTAssertEqual(current?.fee, 3)

        // A later attempt's failure takes the row, and then owns it.
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 700, feeSats: 0, at: 300), railPaymentId: "third")
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 500, feeSats: 3, at: 300), railPaymentId: "retry")
        current = try await row()
        XCTAssertEqual(current?.value, 700)
    }

    func testChannelFreeRowAttemptsKeepTheLatestRowWritersUpToTheLimit() throws {
        let suite = "ChannelFreeRowAttemptsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let attempts = ChannelFreeRowAttempts(defaults: defaults)
        for index in 0 ... ChannelFreeRowAttempts.limit {
            attempts.remember("id\(index)", forPaymentHash: "hash\(index)")
        }
        attempts.remember("newer", forPaymentHash: "HASH1")

        XCTAssertNil(attempts.attemptId(forPaymentHash: "hash0"))
        XCTAssertEqual(attempts.attemptId(forPaymentHash: "hash1"), "newer")
        XCTAssertEqual(attempts.attemptId(forPaymentHash: "hash\(ChannelFreeRowAttempts.limit)"), "id\(ChannelFreeRowAttempts.limit)")
    }

    func testASameSecondFailureTakesTheRowOnlyAsTheSendAfterTheRowsAttempt() {
        // The row's own attempt, and a row or failure without an id, write it.
        XCTAssertFalse(ActivityService.isOtherRowAttempt("first", rowAttemptId: "first"))
        XCTAssertFalse(ActivityService.isOtherRowAttempt(nil, rowAttemptId: "first"))
        XCTAssertFalse(ActivityService.isOtherRowAttempt("retry", rowAttemptId: nil))
        // Another attempt of the same second keeps the row when nothing orders the two.
        XCTAssertTrue(ActivityService.isOtherRowAttempt("first", rowAttemptId: "retry"))
        XCTAssertTrue(ActivityService.isOtherRowAttempt("first", rowAttemptId: "retry", earlierAttemptIds: ["older"]))
        // The retry in flight lists the row's attempt before it, so its failure takes the row.
        XCTAssertFalse(ActivityService.isOtherRowAttempt("retry", rowAttemptId: "first", earlierAttemptIds: ["first"]))
        // While it is in flight, an attempt it lists as earlier still keeps the row.
        XCTAssertTrue(ActivityService.isOtherRowAttempt("older", rowAttemptId: "first", earlierAttemptIds: ["first", "older"]))
    }
}
