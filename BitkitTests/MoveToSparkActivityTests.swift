@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

/// A move pays the wallet's own Spark invoice from the channels: the LDK send and the Spark receive share one hash.
final class MoveToSparkActivityTests: XCTestCase {
    private let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("MoveToSparkActivityTests-\(UUID().uuidString)", isDirectory: true)
    private let paymentHash = String(repeating: "ab", count: 32)
    private let invoice = "lnbcrt50u1movetospark"
    private let movedSats: UInt64 = 5000
    private let routingFeeSats: UInt64 = 3

    override func setUp() async throws {
        try await super.setUp()
        snapshotAppDefaults("activityDetachedContacts")
        _ = Bitkit.CoreService.shared
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        _ = try initDb(basePath: database.path)
    }

    override func tearDown() async throws {
        await drainCoreServiceQueue()
        await repointCoreToAppStorage()
        try? FileManager.default.removeItem(at: database)
        try await super.tearDown()
    }

    func testSparkReceiveAfterTheLdkSendKeepsOneOutgoingRow() async throws {
        let activity = Bitkit.CoreService.shared.activity
        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1000)])
        try await activity.recordChannelFreeRailPayment(sparkReceive(timestamp: 1001))

        try await assertOneOutgoingRowWithTheRoutingFee()
    }

    func testLdkSendAfterTheSparkReceiveReplacesItWithOneOutgoingRow() async throws {
        let activity = Bitkit.CoreService.shared.activity
        try await activity.recordChannelFreeRailPayment(sparkReceive(timestamp: 1001))
        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1000)])
        try await activity.recordChannelFreeRailPayment(sparkReceive(timestamp: 1002))

        try await assertOneOutgoingRowWithTheRoutingFee()
    }

    func testSparkReceiveWaitingOnItsContactLookupKeepsTheLdkSendStoredMeanwhile() async throws {
        let activity = Bitkit.CoreService.shared.activity
        let send = ldkSend(timestamp: 1000)
        // The receive's contact lookup is where it waits; the send lands in that gap.
        activity.setPrivatePaykitContactResolvers(
            invoice: { _ in
                try? await Bitkit.CoreService.shared.activity.syncLdkNodePayments([send])
                return nil
            },
            onchainAddresses: nil
        )
        defer { activity.setPrivatePaykitContactResolvers(invoice: nil, onchainAddresses: nil) }
        try await activity.recordChannelFreeRailPayment(sparkReceive(timestamp: 1001))

        try await assertOneOutgoingRowWithTheRoutingFee()
    }

    func testSucceededSparkReceiveSettlesAPendingLdkSend() async throws {
        let activity = Bitkit.CoreService.shared.activity
        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1000, status: .pending)])
        try await activity.recordChannelFreeRailPayment(sparkReceive(timestamp: 1001))

        try await assertOneOutgoingRowWithTheRoutingFee()
    }

    func testSparkReceiveSettlingTheSendTakesTheRoutingFeeFromTheLaterLdkUpdate() async throws {
        let activity = Bitkit.CoreService.shared.activity
        // A pending send has no fee yet; the receive's settle stamps the row after the node's later update.
        try await activity.syncLdkNodePayments([
            payment(direction: .outbound, feeSats: nil, timestamp: 1000, status: .pending),
        ])
        try await activity.recordChannelFreeRailPayment(sparkReceive(timestamp: 1001))
        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1002)])

        try await assertOneOutgoingRowWithTheRoutingFee()
    }

    func testPendingLdkSendKeepsTheSucceededSparkReceiveUntilTheSendSucceeds() async throws {
        let activity = Bitkit.CoreService.shared.activity
        try await activity.recordChannelFreeRailPayment(sparkReceive(timestamp: 1000))
        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1001, status: .pending)])

        let rows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
        XCTAssertEqual(rows.count, 1)
        guard case let .lightning(row) = try XCTUnwrap(rows.first) else {
            return XCTFail("Expected a lightning activity")
        }
        XCTAssertEqual(row.txType, .received)
        XCTAssertEqual(row.status, .succeeded)

        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1002)])

        try await assertOneOutgoingRowWithTheRoutingFee()
    }

    func testAPartSettlingAfterARelaunchDropsTheFailedPartItReplacedSyncedBefore() async throws {
        try await assertARelaunchedPartDropsItsRetriedPart(failedFirst: true)
    }

    func testAPartSettlingAfterARelaunchDropsTheFailedPartItReplacedSyncedAfter() async throws {
        try await assertARelaunchedPartDropsItsRetriedPart(failedFirst: false)
    }

    func testAPartFailingAfterARelaunchKeepsTheFailedPartItWouldHaveReplaced() async throws {
        try await withRelaunchStores { defaults in
            let retriedHash = String(repeating: "ef", count: 32)
            Bitkit.ActivityService.retriedMoveParts.set([retriedHash], before: paymentHash)

            try await Bitkit.CoreService.shared.activity.syncLdkNodePayments([
                ldkSend(timestamp: 900, status: .failed, hash: retriedHash),
                ldkSend(timestamp: 1000, status: .failed),
            ])

            let rows = try await Bitkit.CoreService.shared.activity.get(filter: .lightning, walletId: WalletScope.default)
            XCTAssertEqual(rows.count, 2, "A failed part left Activity though nothing replaced it")
            XCTAssertNil(Bitkit.RetriedMoveParts(defaults: defaults).take(before: paymentHash))
        }
    }

    private func withRelaunchStores(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "MoveToSparkActivityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let savedDropped = Bitkit.ActivityService.droppedMovePayments
        let savedRetried = Bitkit.ActivityService.retriedMoveParts
        Bitkit.ActivityService.droppedMovePayments = Bitkit.DroppedMovePayments(defaults: defaults)
        Bitkit.ActivityService.retriedMoveParts = Bitkit.RetriedMoveParts(defaults: defaults)
        defer {
            Bitkit.ActivityService.droppedMovePayments = savedDropped
            Bitkit.ActivityService.retriedMoveParts = savedRetried
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await body(defaults)
    }

    private func assertARelaunchedPartDropsItsRetriedPart(failedFirst: Bool) async throws {
        try await withRelaunchStores { _ in try await assertARelaunchedPartDropsItsRetriedPartInStores(failedFirst: failedFirst) }
    }

    private func assertARelaunchedPartDropsItsRetriedPartInStores(failedFirst: Bool) async throws {
        let activity = Bitkit.CoreService.shared.activity
        let retriedHash = String(repeating: "ef", count: 32)
        // Kept before the relaunch, while the smaller part was in flight.
        Bitkit.ActivityService.retriedMoveParts.set([retriedHash], before: paymentHash)
        let failed = ldkSend(timestamp: 900, status: .failed, hash: retriedHash)
        let settled = ldkSend(timestamp: 1000)

        if failedFirst {
            try await activity.syncLdkNodePayments([failed])
        }
        try await activity.syncLdkNodePayments(failedFirst ? [failed, settled] : [settled, failed])

        let rows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
        let ids = rows.compactMap { row -> String? in
            guard case let .lightning(ln) = row else { return nil }
            return ln.id
        }
        XCTAssertEqual(ids, [paymentHash], "The failed part a settled smaller part replaced stayed in Activity")
    }

    func testAFailedRetriedPartLeavesActivityOnceMarked() async throws {
        let activity = Bitkit.CoreService.shared.activity
        let suiteName = "MoveToSparkActivityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let saved = Bitkit.ActivityService.droppedMovePayments
        Bitkit.ActivityService.droppedMovePayments = Bitkit.DroppedMovePayments(defaults: defaults)
        defer {
            Bitkit.ActivityService.droppedMovePayments = saved
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1000, status: .failed)])
        let failedRows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
        XCTAssertEqual(failedRows.count, 1, "A failed part nothing retried lost its row")

        Bitkit.ActivityService.droppedMovePayments.insert([paymentHash.uppercased()])
        try await activity.syncLdkNodePayments([ldkSend(timestamp: 1000, status: .failed)])
        let rows = try await activity.get(filter: .lightning, walletId: WalletScope.default)
        XCTAssertTrue(rows.isEmpty, "The failed send of a retried part stayed in Activity")
    }

    private func assertOneOutgoingRowWithTheRoutingFee(file: StaticString = #filePath, line: UInt = #line) async throws {
        let rows = try await Bitkit.CoreService.shared.activity.get(filter: .lightning, walletId: WalletScope.default)
        XCTAssertEqual(rows.count, 1, file: file, line: line)
        guard case let .lightning(row) = try XCTUnwrap(rows.first, file: file, line: line) else {
            return XCTFail("Expected a lightning activity", file: file, line: line)
        }
        XCTAssertEqual(row.id, paymentHash, file: file, line: line)
        XCTAssertEqual(row.txType, .sent, file: file, line: line)
        XCTAssertEqual(row.status, .succeeded, file: file, line: line)
        XCTAssertEqual(row.value, movedSats, file: file, line: line)
        XCTAssertEqual(row.fee, routingFeeSats, file: file, line: line)
    }

    private func ldkSend(timestamp: UInt64, status: LDKNode.PaymentStatus = .succeeded, hash: String? = nil) -> LDKNode.PaymentDetails {
        payment(direction: .outbound, feeSats: routingFeeSats, timestamp: timestamp, status: status, hash: hash)
    }

    private func sparkReceive(timestamp: UInt64) -> LDKNode.PaymentDetails {
        payment(direction: .inbound, feeSats: 0, timestamp: timestamp)
    }

    private func payment(
        direction: LDKNode.PaymentDirection,
        feeSats: UInt64?,
        timestamp: UInt64,
        status: LDKNode.PaymentStatus = .succeeded,
        hash: String? = nil
    ) -> LDKNode.PaymentDetails {
        LDKNode.PaymentDetails(
            id: hash ?? paymentHash,
            kind: .bolt11(
                hash: hash ?? paymentHash,
                preimage: String(repeating: "cd", count: 32),
                secret: nil,
                description: "Move to Spark",
                bolt11: invoice
            ),
            amountMsat: movedSats * 1000,
            feePaidMsat: feeSats.map { $0 * 1000 },
            direction: direction,
            status: status,
            latestUpdateTimestamp: timestamp
        )
    }
}
