@testable import Bitkit
import BitkitCore
import XCTest

final class BlocktankTests: XCTestCase {
    /// Unique per run: `NSTemporaryDirectory()` is shared with every other suite that calls
    /// `initDb`, and `init_db` creates blocktank.db alongside activity.db, which none of them
    /// cleaned up.
    let testDbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("BlocktankTests-\(UUID().uuidString)", isDirectory: true).path
    let service = CoreService.shared.blocktank

    override func setUp() async throws {
        try await super.setUp()
        await drainCoreServiceQueue()
        try FileManager.default.createDirectory(atPath: testDbPath, withIntermediateDirectories: true)
        // Initialize the database before each test
        _ = try initDb(basePath: testDbPath)
        try await updateBlocktankUrl(newUrl: Env.blocktankClientServer)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        await repointCoreToAppStorage()
        try? FileManager.default.removeItem(atPath: testDbPath)
    }

    func testGetInfo() async throws {
        // Test getting info with and without refresh
        guard let info = try await service.info() else {
            XCTFail("Info should not be nil")
            return
        }

        // Verify info structure
        // Test options
        XCTAssertGreaterThan(info.options.minChannelSizeSat, 0, "Minimum channel size should be greater than 0")
        XCTAssertGreaterThan(info.options.maxChannelSizeSat, info.options.minChannelSizeSat, "Maximum channel size should be greater than minimum")
        XCTAssertGreaterThan(info.options.minExpiryWeeks, 0, "Minimum expiry weeks should be greater than 0")
        XCTAssertGreaterThan(info.options.maxExpiryWeeks, info.options.minExpiryWeeks, "Maximum expiry weeks should be greater than minimum")

        // Test nodes
        XCTAssertFalse(info.nodes.isEmpty, "LSP nodes list should not be empty")
        for node in info.nodes {
            XCTAssertFalse(node.pubkey.isEmpty, "Node pubkey should not be empty")
            XCTAssertFalse(node.connectionStrings.isEmpty, "Node connection strings should not be empty")
        }

        // Test versions
        XCTAssertFalse(info.versions.http.isEmpty, "HTTP version should not be empty")
        XCTAssertFalse(info.versions.btc.isEmpty, "BTC version should not be empty")
        XCTAssertFalse(info.versions.ln2.isEmpty, "LN2 version should not be empty")

        // Test onchain info
        XCTAssertGreaterThan(info.onchain.feeRates.fast, 0, "Fast fee rate should be greater than 0")
        XCTAssertGreaterThan(info.onchain.feeRates.mid, 0, "Mid fee rate should be greater than 0")
        XCTAssertGreaterThan(info.onchain.feeRates.slow, 0, "Slow fee rate should be greater than 0")
    }

    func testPerformanceExample() {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }
}
