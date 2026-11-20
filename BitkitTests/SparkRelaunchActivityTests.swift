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

    func testASameSecondRetryTakesTheRowAfterItsHoldEnded() async throws {
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "ea", count: 16)
        func failed(sats: UInt64, feeSats: UInt64, at timestamp: UInt64) -> PaymentDetails {
            PaymentDetails(
                id: hash,
                kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
                amountMsat: sats * 1000, feePaidMsat: feeSats * 1000, direction: .outbound, status: .failed, latestUpdateTimestamp: timestamp
            )
        }
        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 300, feeSats: 1, at: 200), railPaymentId: "first")
        // A retry in the same second followed the first attempt, and a listing that showed it failed ended its hold
        // before its own failure was recorded: only the attempts kept past the hold still order the two.
        LightningService.shared.keepEarlierAttemptsForTesting(hash: hash, ids: ["first"])

        try await CoreService.shared.activity.recordChannelFreeRailPayment(failed(sats: 500, feeSats: 0, at: 200), railPaymentId: "retry")
        guard case let .lightning(row)? = try await CoreService.shared.activity.getActivity(id: hash) else {
            return XCTFail("the row is missing")
        }
        XCTAssertEqual(row.value, 500, "the first attempt's amount stayed over the retry's")
        XCTAssertEqual(row.fee, 0)
    }

    func testChannelFreeRowAttemptsKeepTheLatestRowWritersUpToTheLimit() throws {
        let suite = "ChannelFreeRowAttemptsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let attempts = ChannelFreeRowAttempts(defaults: defaults)
        for index in 0 ... ChannelFreeRowAttempts.limit {
            attempts.remember("id\(index)", forPaymentHash: "hash\(index)", stamp: "1:2:3")
        }
        attempts.remember("newer", forPaymentHash: "HASH1", stamp: "1:2:3")
        // A failed row write puts the writer before it back, or removes the one it added.
        let before = attempts.entry(forPaymentHash: "hash1")
        attempts.remember("failed-write", forPaymentHash: "hash1", stamp: "4:5:6")
        attempts.restore(before, forPaymentHash: "hash1")
        attempts.remember("unwritten", forPaymentHash: "fresh", stamp: "1:2:3")
        attempts.restore(nil, forPaymentHash: "fresh")
        XCTAssertNil(attempts.attemptId(forPaymentHash: "fresh"))

        XCTAssertNil(attempts.attemptId(forPaymentHash: "hash0"))
        XCTAssertEqual(attempts.attemptId(forPaymentHash: "hash1"), "newer")
        XCTAssertEqual(attempts.attemptId(forPaymentHash: "hash\(ChannelFreeRowAttempts.limit)"), "id\(ChannelFreeRowAttempts.limit)")
    }

    func testChannelFreeRowAttemptsKeepARetriedSendsWriterPastTheLatestSends() throws {
        let suite = "ChannelFreeRowAttemptsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([["retried", "earlier"]], forKey: LightningService.keptRailSendEarlierAttemptsKey)
        let attempts = ChannelFreeRowAttempts(defaults: defaults)
        attempts.remember("original", forPaymentHash: "retried", stamp: "1:2:3")
        attempts.remember("id", forPaymentHash: "plain", stamp: "1:2:3")
        for index in 0 ..< ChannelFreeRowAttempts.limit {
            attempts.remember("id\(index)", forPaymentHash: "later\(index)", stamp: "1:2:3")
        }

        XCTAssertEqual(attempts.entry(forPaymentHash: "retried"), ["retried", "original", "1:2:3", "", ""])
        XCTAssertNil(attempts.entry(forPaymentHash: "plain"))
        XCTAssertEqual(attempts.attemptId(forPaymentHash: "later0"), "id0")
        XCTAssertEqual((defaults.array(forKey: "channelFreeRowAttemptIds") as? [[String]])?.count, ChannelFreeRowAttempts.limit + 1)
    }

    func testChannelFreeRowAttemptsKeepANewSendsWriterBesideAFullSetOfRetriedSends() throws {
        let suite = "ChannelFreeRowAttemptsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let retried = (0 ..< ChannelFreeRowAttempts.limit).map { "retried\($0)" }
        defaults.set(retried.map { [$0, "earlier"] }, forKey: LightningService.keptRailSendEarlierAttemptsKey)
        let attempts = ChannelFreeRowAttempts(defaults: defaults)
        for hash in retried {
            attempts.remember("id", forPaymentHash: hash, stamp: "1:2:3")
        }
        attempts.remember("new", forPaymentHash: "plain", stamp: "1:2:3")

        XCTAssertEqual(attempts.attemptId(forPaymentHash: "plain"), "new")
        XCTAssertEqual(attempts.attemptId(forPaymentHash: "retried0"), "id")
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

    func testFailingAHeldSparkRowInPlaceKeepsAWriterItDidntFollow() async throws {
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "e9", count: 16)
        let pending = PaymentDetails(
            id: hash,
            kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
            amountMsat: 500_000, feePaidMsat: 0, direction: .outbound, status: .pending, latestUpdateTimestamp: 200
        )
        try await CoreService.shared.activity.recordChannelFreeRailPayment(pending, railPaymentId: "earlier")
        XCTAssertEqual(ActivityService.channelFreeRowAttempts.attemptId(forPaymentHash: hash), "earlier")

        // An attempt that isn't one the held send followed stays the row's writer.
        try await CoreService.shared.activity.failPendingLightningSend(id: hash, earlierAttemptIds: ["older"])
        XCTAssertEqual(ActivityService.channelFreeRowAttempts.attemptId(forPaymentHash: hash), "earlier")
    }

    func testFailingAHeldSparkRowInPlaceMakesItTheHeldAttemptsOwn() async throws {
        func pendingRow(_ hash: String) async throws {
            let pending = PaymentDetails(
                id: hash,
                kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
                amountMsat: 500_000, feePaidMsat: 0, direction: .outbound, status: .pending, latestUpdateTimestamp: 200
            )
            try await CoreService.shared.activity.recordChannelFreeRailPayment(pending, railPaymentId: "earlier")
        }
        let taken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "ea", count: 16)
        try await pendingRow(taken)
        // The held send's own id becomes the writer, so it keeps the row against an older failure of the same second.
        try await CoreService.shared.activity.failPendingLightningSend(id: taken, ownAttemptId: "retry", earlierAttemptIds: ["earlier"])
        XCTAssertEqual(ActivityService.channelFreeRowAttempts.attemptId(forPaymentHash: taken), "retry")

        let owned = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "eb", count: 16)
        try await pendingRow(owned)
        // Without its own id, a row the earlier attempt still owns keeps its writer, so that attempt's final fee lands.
        try await CoreService.shared.activity.failPendingLightningSend(id: owned, earlierAttemptIds: ["earlier"])
        XCTAssertEqual(ActivityService.channelFreeRowAttempts.attemptId(forPaymentHash: owned), "earlier")

        let overwritten = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "ec", count: 16)
        try await pendingRow(overwritten)
        // The retry's send wrote over the earlier attempt's row without a Spark id, so that attempt no longer owns it.
        guard case var .lightning(row)? = try await CoreService.shared.activity.getActivity(id: overwritten) else {
            return XCTFail("the earlier attempt's row is missing")
        }
        row.value = 700
        try await CoreService.shared.activity.update(id: overwritten, activity: .lightning(row))
        try await CoreService.shared.activity.failPendingLightningSend(id: overwritten, earlierAttemptIds: ["earlier"])
        XCTAssertNil(ActivityService.channelFreeRowAttempts.attemptId(forPaymentHash: overwritten))
    }

    func testAStopBetweenKeepingAWriterAndSavingItsRowLeavesTheRowToItsRealWriter() async throws {
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + String(repeating: "ed", count: 16)
        let pending = PaymentDetails(
            id: hash,
            kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: "lnbcrt1"),
            amountMsat: 500_000, feePaidMsat: 0, direction: .outbound, status: .pending, latestUpdateTimestamp: 200
        )
        try await CoreService.shared.activity.recordChannelFreeRailPayment(pending, railPaymentId: "earlier")
        guard case let .lightning(row)? = try await CoreService.shared.activity.getActivity(id: hash) else {
            return XCTFail("the earlier payment's row is missing")
        }
        let attempts = ActivityService.channelFreeRowAttempts
        // The retry's writer was kept, then the app stopped before its row was saved.
        attempts.remember("retry", forPaymentHash: hash, stamp: "300:700:0", previousRowStamp: ChannelFreeRowAttempts.stamp(row))
        XCTAssertEqual(attempts.attemptId(forPaymentHash: hash, row: row), "earlier")
        XCTAssertTrue(attempts.isUnchanged(row, forPaymentHash: hash))

        // A second write cut off the same way, or one alike the row, still leaves it to its real writer.
        attempts.remember("third", forPaymentHash: hash, stamp: "400:800:0", previousRowStamp: ChannelFreeRowAttempts.stamp(row))
        XCTAssertEqual(attempts.attemptId(forPaymentHash: hash, row: row), "earlier")
        attempts.remember(
            "alike",
            forPaymentHash: hash,
            stamp: ChannelFreeRowAttempts.stamp(row),
            previousRowStamp: ChannelFreeRowAttempts.stamp(row)
        )
        XCTAssertEqual(attempts.attemptId(forPaymentHash: hash, row: row), "earlier")
        attempts.remember("retry", forPaymentHash: hash, stamp: "300:700:0", previousRowStamp: ChannelFreeRowAttempts.stamp(row))
        XCTAssertEqual(attempts.attemptId(forPaymentHash: hash, row: row), "earlier")

        // Once the retry's row is saved, it is the retry's.
        attempts.commit(forPaymentHash: hash)
        XCTAssertEqual(attempts.attemptId(forPaymentHash: hash, row: row), "retry")
        XCTAssertFalse(attempts.isUnchanged(row, forPaymentHash: hash))
    }
}
