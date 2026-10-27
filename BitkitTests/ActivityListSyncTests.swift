@testable import Bitkit
import BitkitCore
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
