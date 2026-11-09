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

    private func ldkSend(timestamp: UInt64) -> LDKNode.PaymentDetails {
        payment(direction: .outbound, feeSats: routingFeeSats, timestamp: timestamp)
    }

    private func sparkReceive(timestamp: UInt64) -> LDKNode.PaymentDetails {
        payment(direction: .inbound, feeSats: 0, timestamp: timestamp)
    }

    private func payment(direction: LDKNode.PaymentDirection, feeSats: UInt64, timestamp: UInt64) -> LDKNode.PaymentDetails {
        LDKNode.PaymentDetails(
            id: paymentHash,
            kind: .bolt11(
                hash: paymentHash,
                preimage: String(repeating: "cd", count: 32),
                secret: nil,
                description: "Move to Spark",
                bolt11: invoice
            ),
            amountMsat: movedSats * 1000,
            feePaidMsat: feeSats * 1000,
            direction: direction,
            status: .succeeded,
            latestUpdateTimestamp: timestamp
        )
    }
}
