@testable import Bitkit
import XCTest

/// The next exit funding index across a restore: carried by the metadata backup, else found by a scan of the funding
/// addresses.
@MainActor
final class SparkExitFundingIndexTests: XCTestCase {
    private let suiteName = "SparkExitFundingIndexTests"
    private var defaults: UserDefaults!
    private let key = SparkExitFundingIndexes.defaultsKey(network: "regtest", walletIndex: 0)

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testARestoreKeepsTheHigherIndexOfTheDeviceAndTheBackup() {
        defaults.set(5, forKey: key)

        SparkExitFundingIndexes.restore(["regtest/wallet0": 3, "regtest/wallet1": 2], into: defaults)

        XCTAssertEqual(defaults.integer(forKey: key), 5, "an exit would fund from an address an earlier exit used")
        XCTAssertEqual(defaults.integer(forKey: SparkExitFundingIndexes.defaultsKey(network: "regtest", walletIndex: 1)), 2)
    }

    func testAMetadataBackupWrittenBeforeTheIndexDecodesWithNone() throws {
        let json = #"{"version":1,"createdAt":1,"tagMetadata":[],"cache":{"hasSeenContactsIntro":true}}"#

        let backup = try JSONDecoder().decode(MetadataBackupV1.self, from: Data(json.utf8))

        XCTAssertTrue(backup.cache.hasSeenContactsIntro)
        XCTAssertNil(backup.cache.sparkExitNextFundingIndexes)
    }
}
