@testable import Bitkit
import BitkitCore
import LDKNode
import XCTest

final class ActivityListSyncTests: XCTestCase {
    private let database = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityListSyncTests-\(UUID().uuidString)", isDirectory: true)

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

    @MainActor
    func testWipeDrainsPaymentEnumerationBeforeClearingTheOriginalWallet() async throws {
        let admission = ProfileOperationAdmission(store: ProfileRemovalStore(url: database.appendingPathComponent("pending.json")))
        let activity = Bitkit.ActivityService(coreService: .shared)
        activity.setPrivatePaykitContactResolvers(invoice: nil, onchainAddresses: nil,
                                                  receiptOperation: { try await admission.withReceiptAttribution($0) })
        let originalActivity = Bitkit.CoreService.shared.activity
        Bitkit.CoreService.shared.activity = activity
        defer { Bitkit.CoreService.shared.activity = originalActivity }
        let entered = expectation(description: "Payment enumeration suspended")
        var continuation: CheckedContinuation<Void, Never>?
        let hash = String(repeating: "a", count: 64)
        let payment = LDKNode.PaymentDetails(
            id: hash, kind: .bolt11(hash: hash, preimage: nil, secret: nil, description: nil, bolt11: nil),
            amountMsat: 5_000_000, feePaidMsat: 0, direction: .inbound, status: .succeeded,
            latestUpdateTimestamp: UInt64(Date().timeIntervalSince1970)
        )
        let model = Bitkit.ActivityListViewModel(transferService: Bitkit.TransferService(
            lightningService: .shared, blocktankService: Bitkit.CoreService.shared.blocktank
        ), listPayments: {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
            return [payment]
        })
        let syncing = Task { try await model.syncLdkNodePayments() }
        await fulfillment(of: [entered], timeout: 3)
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        defer { admission.release(wipe) }
        XCTAssertThrowsError(try admission.persist(wipe), "Payment enumeration still owns its receipt work")
        let wiping = Task {
            try await admission.drain(before: wipe)
            try admission.persist(wipe)
            try await activity.removeAll()
        }
        continuation?.resume()
        do {
            try await syncing.value
            XCTFail("Old payment enumeration entered storage after wipe reservation")
        } catch is ProfileRemovalStore.StoreError {}
        try await wiping.value
        try admission.complete(wipe)
        admission.release(wipe)
        let rows = try await activity.get(walletId: WalletScope.default)
        XCTAssertTrue(rows.isEmpty)
        try await activity.syncLdkNodePayments([payment])
        let replacementRows = try await activity.get(walletId: WalletScope.default)
        XCTAssertEqual(replacementRows.count, 1, "Fresh replacement sync must be admitted after wipe releases")
    }

    @MainActor
    func testOverlappingSyncsDoNotLoadPaymentsAndUnavailableNodeAllowsRetry() async throws {
        let started = expectation(description: "First payment list suspended")
        var resume: CheckedContinuation<Void, Never>?
        var loads = 0
        let model = Bitkit.ActivityListViewModel(
            transferService: Bitkit.TransferService(
                lightningService: .shared,
                blocktankService: Bitkit.CoreService.shared.blocktank
            ),
            listPayments: {
                loads += 1
                if loads == 1 {
                    await withCheckedContinuation {
                        resume = $0
                        started.fulfill()
                    }
                }
                return nil
            }
        )
        let first = Task { try await model.syncLdkNodePayments() }
        await fulfillment(of: [started], timeout: 5)

        // Reproduce the burst of refresh callers while the node queue is suspended.
        for _ in 0 ..< 256 {
            try await model.syncLdkNodePayments()
        }
        let overlappingLoads = loads
        resume?.resume()
        try await first.value
        XCTAssertEqual(overlappingLoads, 1)

        // A nil list (node not ready) must release admission for a later refresh.
        try await model.syncLdkNodePayments()
        XCTAssertEqual(loads, 2)
    }
}
