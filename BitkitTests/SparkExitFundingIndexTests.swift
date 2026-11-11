@testable import Bitkit
import XCTest

/// The next exit funding index across a restore: carried by the metadata backup, else found by a scan of the funding
/// addresses.
@MainActor
final class SparkExitFundingIndexTests: XCTestCase {
    private let suiteName = "SparkExitFundingIndexTests"
    private var defaults: UserDefaults!
    private let chain = FakeSparkExitChain()
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

    private func address(_ index: UInt32) -> String {
        "bcrt1qfunding\(index)"
    }

    private func nextFundingIndex() async throws -> UInt32 {
        try await SparkExitManager.nextFundingIndex(defaults: defaults, key: key, record: nil, chain: chain) { self.address($0) }
    }

    /// What a new device holds after a restore: the app's data is gone, and only the backed-up cache comes back.
    private func restore(_ cache: AppCacheData) {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        SparkExitFundingIndexes.restore(cache.sparkExitNextFundingIndexes, into: defaults)
    }

    private func roundTrip(_ cache: AppCacheData) throws -> AppCacheData {
        try JSONDecoder().decode(AppCacheData.self, from: JSONEncoder().encode(cache))
    }

    private func cache(sparkExitNextFundingIndexes: [String: Int]?) -> AppCacheData {
        AppCacheData(
            hasSeenContactsIntro: false,
            hasSeenProfileIntro: false,
            hasSeenNotificationsIntro: false,
            hasSeenQuickpayIntro: false,
            hasSeenShopIntro: false,
            hasSeenTransferToSavingsIntro: false,
            hasSeenWidgetsIntro: false,
            hasDismissedWidgetsOnboardingHint: false,
            appUpdateIgnoreTimestamp: 0,
            backupIgnoreTimestamp: 0,
            highBalanceIgnoreCount: 0,
            highBalanceIgnoreTimestamp: 0,
            dismissedSuggestions: [],
            lastUsedTags: [],
            sparkExitNextFundingIndexes: sparkExitNextFundingIndexes
        )
    }

    /// Funding indexes 0 to 2 were used before the restore; index 2 still holds what a lost exit received.
    func testARestoreFromABackupWithoutTheIndexScansPastTheFundingItsLastExitUsed() async throws {
        defaults.set(3, forKey: key)
        let oldBackup = try JSONDecoder().decode(AppCacheData.self, from: Data("{}".utf8))
        restore(oldBackup)
        chain.usedAddresses = [address(0), address(1)]
        chain.utxosByAddress[address(2)] = [SparkExitFixtures.utxo("lost", value: 5000)]

        let next = try await nextFundingIndex()

        XCTAssertEqual(next, 3)
        XCTAssertTrue(chain.addressReads.contains(address(2)), "the funding at index 2 goes unseen")
        XCTAssertEqual(chain.addressReads, (0 ... 2 + SparkExitMath.fundingScanGapLimit).map(address))
        XCTAssertEqual(defaults.object(forKey: key) as? Int, 3, "the next quote scans again")
    }

    func testAFundingIndexRestoredFromTheBackupIsUsedWithoutAScan() async throws {
        defaults.set(3, forKey: key)
        let backup = try roundTrip(cache(sparkExitNextFundingIndexes: SparkExitFundingIndexes.backup(defaults)))
        restore(backup)
        chain.usedAddresses = [address(0), address(1), address(2)]

        let next = try await nextFundingIndex()

        XCTAssertEqual(backup.sparkExitNextFundingIndexes, ["regtest/wallet0": 3], "keyed as bitkit-android keys it")
        XCTAssertEqual(next, 3)
        XCTAssertTrue(chain.addressReads.isEmpty, "a backed-up index needs no scan")
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

    func testAFundingScanTheChainFailsKeepsNoIndex() async {
        chain.isAddressReadUnreadable = true

        do {
            _ = try await nextFundingIndex()
            XCTFail("an exit could fund from an address an earlier exit used")
        } catch {}

        XCTAssertNil(defaults.object(forKey: key))
    }

    func testAFundingScanReadsTheGapLimitPastTheLastUsedAddress() async {
        var reads: [UInt32] = []

        let next = await SparkExitMath.scanNextFundingIndex { index in
            reads.append(index)
            return [0, 2, 5].contains(index)
        }

        XCTAssertEqual(next, 6)
        XCTAssertEqual(reads, Array(0 ... 5 + SparkExitMath.fundingScanGapLimit))
    }

    func testAFundingScanStopsAtItsCeilingWhenEveryAddressReadsAsUsed() async {
        var reads: UInt32 = 0

        let next = await SparkExitMath.scanNextFundingIndex { _ in
            reads += 1
            return true
        }

        XCTAssertEqual(next, SparkExitMath.fundingScanMaxAddresses)
        XCTAssertEqual(reads, SparkExitMath.fundingScanMaxAddresses)
    }

    func testAnAddressWithATransactionInABlockOrTheMempoolReadsAsUsed() async throws {
        let http = SparkExitBroadcasterTests.FakeHTTP()
        let stats = { (chain: Int, mempool: Int) in
            #"{"chain_stats":{"tx_count":\#(chain)},"mempool_stats":{"tx_count":\#(mempool)}}"#
        }
        http.responses = [
            ("a.example/api/address/bcrt1qmempool", 200, stats(0, 1)),
            ("a.example/api/address/bcrt1qspent", 200, stats(2, 0)),
            ("a.example/api/address/bcrt1qfresh", 200, stats(0, 0)),
        ]
        let esplora = try EsploraSparkExitChain(hosts: [XCTUnwrap(URL(string: "https://a.example/api"))], http: http)

        let isMempoolUsed = try await esplora.isAddressUsed(address: "bcrt1qmempool")
        let isSpentUsed = try await esplora.isAddressUsed(address: "bcrt1qspent")
        let isFreshUsed = try await esplora.isAddressUsed(address: "bcrt1qfresh")

        XCTAssertTrue(isMempoolUsed)
        XCTAssertTrue(isSpentUsed)
        XCTAssertFalse(isFreshUsed)
    }
}
