@testable import Bitkit
import BitkitCore
import XCTest

final class FailPendingLightningSendTests: XCTestCase {
    private let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailPendingLightningSendTests-\(UUID().uuidString)", isDirectory: true)

    override func setUp() async throws {
        try await super.setUp()
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

    func testFailsOnlyAPendingSend() async throws {
        let activity = Bitkit.CoreService.shared.activity
        let rows: [(id: String, txType: PaymentType, status: PaymentState)] = [
            ("pending-send", .sent, .pending),
            ("paid-send", .sent, .succeeded),
            ("failed-send", .sent, .failed),
            ("pending-receive", .received, .pending),
        ]
        for row in rows {
            try await activity.insert(.lightning(LightningActivity(
                walletId: WalletScope.default, id: row.id, txType: row.txType, status: row.status, value: 1000, fee: 0,
                invoice: "invoice", message: "", timestamp: 1000, preimage: nil, contact: nil,
                createdAt: 1000, updatedAt: 1000, seenAt: nil
            )))
        }

        for row in rows {
            try await activity.failPendingLightningSend(id: row.id)
        }

        let expected: [String: PaymentState] = [
            "pending-send": .failed, "paid-send": .succeeded, "failed-send": .failed, "pending-receive": .pending,
        ]
        for (id, status) in expected {
            guard case let .lightning(stored) = try await activity.getActivity(id: id) else {
                return XCTFail("\(id) is missing")
            }
            XCTAssertEqual(stored.status, status, id)
        }
    }
}
