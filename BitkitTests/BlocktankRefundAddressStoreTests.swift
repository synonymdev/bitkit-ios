@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class BlocktankRefundAddressStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // `clear()` here and in tearDown, `restoreAppCacheData`, `resetToDefaults()` and the corrupt
        // cache fixture all write UserDefaults.standard — the host app's own preferences.
        snapshotAppDefaultsDomain()
        BlocktankRefundAddressStore().clear()
    }

    func testAppCacheSerializationMatchesSharedOptionalShape() throws {
        let json = #"{"blocktankRefundAddress":{"address":"bcrt1refund","index":7}}"#
        let cache = try JSONDecoder().decode(AppCacheData.self, from: Data(json.utf8))

        XCTAssertEqual(cache.blocktankRefundAddress, BlocktankRefundAddress(address: "bcrt1refund", index: 7))

        let encoded = try JSONEncoder().encode(cache)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let refund = try XCTUnwrap(object["blocktankRefundAddress"] as? [String: Any])
        XCTAssertEqual(refund["address"] as? String, "bcrt1refund")
        XCTAssertEqual(refund["index"] as? Int, 7)
    }

    func testOlderAppCacheWithoutRefundAddressDecodesAsNil() throws {
        let cache = try JSONDecoder().decode(AppCacheData.self, from: Data("{}".utf8))

        XCTAssertNil(cache.blocktankRefundAddress)
    }

    func testStoreKeepsRefundAddressesSeparateByNetwork() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }
        let regtestStore = BlocktankRefundAddressStore(defaults: defaults, network: .regtest)
        let bitcoinStore = BlocktankRefundAddressStore(defaults: defaults, network: .bitcoin)
        let regtestAddress = BlocktankRefundAddress(address: "bcrt1qrefund", index: 7)
        let bitcoinAddress = BlocktankRefundAddress(address: "bc1qrefund", index: 9)

        try regtestStore.save(regtestAddress)
        XCTAssertEqual(try regtestStore.load(), regtestAddress)
        XCTAssertNil(try bitcoinStore.load())

        try bitcoinStore.save(bitcoinAddress)
        XCTAssertEqual(try bitcoinStore.load(), bitcoinAddress)
        XCTAssertEqual(try regtestStore.load(), regtestAddress)
    }

    func testLegacyCacheMigratesOnlyWhenPrefixIdentifiesNetwork() throws {
        let cases: [(LDKNode.Network, String)] = [
            (.bitcoin, " bc1qrefund "),
            (.regtest, " bcrt1qrefund "),
        ]

        for (offset, testCase) in cases.enumerated() {
            let suiteName = "\(#function)-\(offset)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let legacy = BlocktankRefundAddress(address: testCase.1, index: 7)
            try defaults.set(JSONEncoder().encode(legacy), forKey: BlocktankRefundAddressStore.legacyKey)

            let store = BlocktankRefundAddressStore(defaults: defaults, network: testCase.0)
            XCTAssertEqual(try store.load(), legacy)
            XCTAssertNil(defaults.object(forKey: BlocktankRefundAddressStore.legacyKey))
            let migrated = try XCTUnwrap(
                defaults.data(forKey: BlocktankRefundAddressStore.key(for: testCase.0))
            )
            XCTAssertEqual(
                try JSONDecoder().decode(BlocktankRefundAddress.self, from: migrated),
                legacy
            )
        }
    }

    func testClearPreservesLegacyCacheFromAnotherNetwork() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }
        let legacy = BlocktankRefundAddress(address: "bcrt1qrefund", index: 7)
        try defaults.set(JSONEncoder().encode(legacy), forKey: BlocktankRefundAddressStore.legacyKey)

        BlocktankRefundAddressStore(defaults: defaults, network: .bitcoin).clear()
        XCTAssertNotNil(defaults.data(forKey: BlocktankRefundAddressStore.legacyKey))

        BlocktankRefundAddressStore(defaults: defaults, network: .regtest).clear()
        XCTAssertNil(defaults.object(forKey: BlocktankRefundAddressStore.legacyKey))
    }

    func testAmbiguousTestnetLegacyCacheIsPreserved() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }
        let legacy = BlocktankRefundAddress(address: "tb1qrefund", index: 7)
        try defaults.set(JSONEncoder().encode(legacy), forKey: BlocktankRefundAddressStore.legacyKey)

        XCTAssertNil(try BlocktankRefundAddressStore(defaults: defaults, network: .testnet).load())
        XCTAssertNil(try BlocktankRefundAddressStore(defaults: defaults, network: .signet).load())
        BlocktankRefundAddressStore(defaults: defaults, network: .testnet).clear()
        BlocktankRefundAddressStore(defaults: defaults, network: .signet).clear()
        XCTAssertNotNil(defaults.data(forKey: BlocktankRefundAddressStore.legacyKey))
    }

    func testScopedCacheTakesPrecedenceOverLegacyCache() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }
        let store = BlocktankRefundAddressStore(defaults: defaults, network: .regtest)
        let scoped = BlocktankRefundAddress(address: "bcrt1qscoped", index: 8)
        let legacy = BlocktankRefundAddress(address: "bc1qlegacy", index: 7)
        try store.save(scoped)
        try defaults.set(JSONEncoder().encode(legacy), forKey: BlocktankRefundAddressStore.legacyKey)

        XCTAssertEqual(try store.load(), scoped)
        XCTAssertNotNil(defaults.data(forKey: BlocktankRefundAddressStore.legacyKey))
    }

    func testUnknownLegacyCacheFailsClosedAndIsCleared() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }
        let legacy = BlocktankRefundAddress(address: "unknown", index: 7)
        try defaults.set(JSONEncoder().encode(legacy), forKey: BlocktankRefundAddressStore.legacyKey)
        let store = BlocktankRefundAddressStore(defaults: defaults, network: .regtest)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? BlocktankRefundAddressError, .invalidCache)
        }
        store.clear()
        XCTAssertNil(defaults.object(forKey: BlocktankRefundAddressStore.legacyKey))
    }

    func testSettingsCacheRestoreRoundTripAndWipe() throws {
        let json = #"{"blocktankRefundAddress":{"address":"bcrt1refund","index":7}}"#
        let restored = try JSONDecoder().decode(AppCacheData.self, from: Data(json.utf8))

        try SettingsViewModel.shared.restoreAppCacheData(restored)

        XCTAssertEqual(
            try SettingsViewModel.shared.getAppCacheData().blocktankRefundAddress,
            BlocktankRefundAddress(address: "bcrt1refund", index: 7)
        )
        XCTAssertTrue(SettingsBackupConfig.appStateKeys.contains(BlocktankRefundAddressStore.key))

        SettingsViewModel.shared.resetToDefaults()
        XCTAssertNil(try BlocktankRefundAddressStore().load())
    }

    func testCorruptLocalCacheIsRejected() throws {
        UserDefaults.standard.set(Data("not-json".utf8), forKey: BlocktankRefundAddressStore.key)

        XCTAssertThrowsError(try BlocktankRefundAddressStore().load()) { error in
            XCTAssertEqual(error as? BlocktankRefundAddressError, .invalidCache)
        }
    }
}
