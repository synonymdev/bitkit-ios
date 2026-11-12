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
    private let pendingKey = SparkExitFundingIndexes.recoveryPendingKey(network: "regtest", walletIndex: 0)
    private var earlierAddressStore: SparkExitEarlierAddressStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SparkExitFundingIndexTests-\(UUID().uuidString).json")
        earlierAddressStore = SparkExitEarlierAddressStore(url: url)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? earlierAddressStore.delete()
        super.tearDown()
    }

    private func address(_ index: UInt32) -> String {
        "bcrt1qfunding\(index)"
    }

    private func path(_ index: UInt32) -> String {
        "m/84'/1'/7797'/0/\(index)"
    }

    private var recovery: SparkExitManager.FundingRecovery {
        SparkExitManager.FundingRecovery(
            defaults: defaults,
            key: key,
            pendingKey: pendingKey,
            record: nil,
            chain: chain,
            earlierAddressStore: earlierAddressStore,
            funding: { [unowned self] in (address($0), path($0)) }
        )
    }

    private func nextFundingIndex() async throws -> UInt32 {
        try await SparkExitManager.nextFundingIndex(recovery, now: now)
    }

    private func keptCoins(_ index: UInt32, sats: UInt64) -> SparkExitEarlierAddress {
        SparkExitEarlierAddress(address: address(index), path: path(index), kind: .keptChange, sats: sats, date: now)
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

    func testAFundingIndexRestoredFromTheBackupIsOnlyScannedForwardFrom() async throws {
        defaults.set(3, forKey: key)
        let backup = try roundTrip(cache(sparkExitNextFundingIndexes: SparkExitFundingIndexes.backup(defaults)))
        restore(backup)
        chain.usedAddresses = [address(0), address(1), address(2)]

        let next = try await nextFundingIndex()

        XCTAssertEqual(backup.sparkExitNextFundingIndexes, ["regtest/wallet0": 3], "keyed as bitkit-android keys it")
        XCTAssertEqual(next, 3)
        XCTAssertEqual(chain.addressReads, (3 ..< 3 + SparkExitMath.fundingScanGapLimit).map(address), "a backed-up index needs no scan below it")
    }

    func testAQuoteWhileARestoreIsPendingScansPastTheRestoredCounterFirst() async throws {
        // The backup carrying counter 4 never landed: address 3 still holds the lost exit's coins.
        SparkExitFundingIndexes.restore(["regtest/wallet0": 3], into: defaults)
        chain.usedAddresses = [address(0), address(1), address(2), address(3)]
        chain.utxosByAddress[address(3)] = [SparkExitFixtures.utxo("lost", value: 7000)]

        let next = try await nextFundingIndex()

        XCTAssertEqual(next, 4, "the next exit funds from the lost exit's address")
        XCTAssertEqual(try earlierAddressStore.load(), [keptCoins(3, sats: 7000)])
        XCTAssertFalse(defaults.bool(forKey: pendingKey))
    }

    func testAQuoteWhileARestoreIsPendingFailsWhenTheScanFails() async {
        SparkExitFundingIndexes.restore(["regtest/wallet0": 3], into: defaults)
        chain.isAddressReadUnreadable = true

        do {
            _ = try await nextFundingIndex()
            XCTFail("a quote could fund from the address a lost exit used")
        } catch {}

        XCTAssertEqual(defaults.integer(forKey: key), 3)
        XCTAssertTrue(defaults.bool(forKey: pendingKey), "the restore no longer runs again")
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

    // MARK: Earlier exit addresses after a restore

    func testARestoredWalletWithNoCounterWatchesTheFundingAddressesThatStillHoldCoins() async throws {
        // Index 2 still holds what a lost exit received; 0 and 1 were spent by earlier exits.
        chain.usedAddresses = [address(0), address(1)]
        chain.utxosByAddress[address(2)] = [SparkExitFixtures.utxo("lost", value: 5000)]

        let next = try await SparkExitManager.recoverFunding(recovery, now: now)

        XCTAssertEqual(next, 3)
        XCTAssertEqual(try earlierAddressStore.load(), [keptCoins(2, sats: 5000)], "the lost funding goes unwatched")
        XCTAssertEqual(defaults.object(forKey: key) as? Int, 3)
    }

    func testAFundingAddressWithHistoryButNoCoinsIsNotWatched() async throws {
        chain.usedAddresses = [address(0)]
        chain.utxosByAddress[address(1)] = [SparkExitFixtures.utxo("lost", value: 700)]

        try await SparkExitManager.recoverFunding(recovery, now: now)

        XCTAssertEqual(try earlierAddressStore.load(), [keptCoins(1, sats: 700)])
    }

    func testARestoredCounterBringsBackTheFundingAddressesThatStillHoldCoins() async throws {
        SparkExitFundingIndexes.restore(["regtest/wallet0": 3], into: defaults)
        chain.usedAddresses = [address(0), address(1)]
        chain.utxosByAddress[address(2)] = [SparkExitFixtures.utxo("lost", value: 5000)]

        try await SparkExitManager.recoverFunding(recovery, now: now)

        XCTAssertEqual(try earlierAddressStore.load(), [keptCoins(2, sats: 5000)], "the lost funding goes unwatched")
        XCTAssertEqual(chain.addressReads, (3 ..< 23).map(address), "a restored counter is scanned forward from, once")
        XCTAssertNil(defaults.object(forKey: pendingKey), "every start reads the funding addresses again")
        XCTAssertEqual(defaults.integer(forKey: key), 3)
    }

    func testARestoredCounterThatPredatesTheLastExitsFundingFindsItsCoins() async throws {
        // The backup carrying counter 4 never landed: the exit that funded address 3 is lost with it.
        SparkExitFundingIndexes.restore(["regtest/wallet0": 3], into: defaults)
        chain.usedAddresses = [address(0), address(1), address(2), address(3)]
        chain.utxosByAddress[address(3)] = [SparkExitFixtures.utxo("lost", value: 7000)]

        let next = try await SparkExitManager.recoverFunding(recovery, now: now)

        XCTAssertEqual(next, 4)
        XCTAssertEqual(try earlierAddressStore.load(), [keptCoins(3, sats: 7000)], "address 3's coins stay hidden")
        XCTAssertEqual(defaults.integer(forKey: key), 4, "the next exit reuses address 3")
    }

    func testARestoredCounterAtAForgottenExitsAddressListsItsLatePaymentAsKeptChange() async throws {
        // The exit at address 3 was forgotten before funding, so the counter went back to 3; a payment came late.
        try earlierAddressStore.add(SparkExitEarlierAddress(address: address(3), path: path(3), kind: .cancelledFunding, sats: nil, date: now))
        SparkExitFundingIndexes.restore(["regtest/wallet0": 3], into: defaults)
        chain.usedAddresses = [address(0), address(1), address(2), address(3)]
        chain.utxosByAddress[address(3)] = [SparkExitFixtures.utxo("late", value: 4000)]

        let next = try await SparkExitManager.recoverFunding(recovery, now: now)

        XCTAssertEqual(next, 4)
        XCTAssertEqual(try earlierAddressStore.load(), [keptCoins(3, sats: 4000)], "the late payment is watched only until its cancel expires")
    }

    func testARestoredCounterPastTheScanCeilingStillScansForward() async throws {
        let ceiling = Int(SparkExitMath.fundingScanMaxAddresses)
        SparkExitFundingIndexes.restore(["regtest/wallet0": ceiling], into: defaults)
        chain.usedAddresses = [address(UInt32(ceiling))]
        chain.utxosByAddress[address(UInt32(ceiling))] = [SparkExitFixtures.utxo("lost", value: 7000)]

        let next = try await SparkExitManager.recoverFunding(recovery, now: now)

        XCTAssertEqual(next, UInt32(ceiling) + 1)
        XCTAssertEqual(try earlierAddressStore.load(), [keptCoins(UInt32(ceiling), sats: 7000)])
    }

    func testAKeptCounterWithNoRestorePendingReadsNoFundingAddress() async throws {
        defaults.set(3, forKey: key)
        chain.utxosByAddress[address(2)] = [SparkExitFixtures.utxo("lost", value: 5000)]

        try await SparkExitManager.recoverFunding(recovery, now: now)

        XCTAssertTrue(chain.addressReads.isEmpty)
        XCTAssertEqual(try earlierAddressStore.load(), [])
    }

    func testTheMetadataBackupCarriesTheEarlierExitAddresses() throws {
        try earlierAddressStore.add(keptCoins(2, sats: 600))
        try earlierAddressStore.add(SparkExitEarlierAddress(address: address(0), path: path(0), kind: .cancelledFunding, sats: nil, date: now))

        let backup = SparkExitEarlierAddressBackup.backup(earlierAddressStore, walletKey: "regtest/wallet0")

        let millis: Int64 = 1_800_000_000_000
        XCTAssertEqual(backup, ["regtest/wallet0": [
            SparkExitEarlierAddressBackupV1(address: address(2), path: path(2), kind: "keptChange", atMillis: millis),
            SparkExitEarlierAddressBackupV1(address: address(0), path: path(0), kind: "cancelledFunding", atMillis: millis),
        ]])
    }

    func testARestoreListsTheBackedUpEarlierAddressesAndKeepsTheDevices() throws {
        let onDevice = keptCoins(1, sats: 600)
        try earlierAddressStore.add(onDevice)
        let backedUp = [
            SparkExitEarlierAddressBackupV1(address: address(1), path: path(1), kind: "cancelledFunding", atMillis: 1000),
            SparkExitEarlierAddressBackupV1(address: address(2), path: path(2), kind: "keptChange", atMillis: 2000),
            SparkExitEarlierAddressBackupV1(address: address(3), path: path(3), kind: "someLaterKind", atMillis: 3000),
        ]

        SparkExitEarlierAddressBackup.restore(["regtest/wallet0": backedUp, "bitcoin/wallet0": backedUp], network: "regtest") { _ in
            self.earlierAddressStore
        }

        let restored = SparkExitEarlierAddress(address: address(2), path: path(2), kind: .keptChange, sats: nil, date: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try earlierAddressStore.load(), [onDevice, restored])
    }

    func testAMetadataBackupWithAnUnreadableEarlierAddressListKeepsTheRest() throws {
        let json = #"{"version":1,"createdAt":1,"tagMetadata":[],"cache":{"hasSeenContactsIntro":true},"sparkExitEarlierAddresses":{"regtest/wallet0":[{"address":1}]}}"#

        let backup = try JSONDecoder().decode(MetadataBackupV1.self, from: Data(json.utf8))

        XCTAssertTrue(backup.cache.hasSeenContactsIntro, "one bad entry fails the whole metadata restore")
        XCTAssertNil(backup.sparkExitEarlierAddresses)
    }
}
