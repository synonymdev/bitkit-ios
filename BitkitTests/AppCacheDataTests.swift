@testable import Bitkit
import XCTest

final class AppCacheDataTests: XCTestCase {
    func testBackupWithRemovedBlocktankKeysStillDecodes() throws {
        let json = #"""
        {
            "hasSeenShopIntro": true,
            "blocktankRefundAddress": {"address": "bcrt1refund", "index": 7},
            "lastUsedTags": ["coffee"]
        }
        """#

        let cache = try JSONDecoder().decode(AppCacheData.self, from: Data(json.utf8))

        XCTAssertTrue(cache.hasSeenShopIntro)
        XCTAssertEqual(cache.lastUsedTags, ["coffee"])
    }

    func testTransferIntroFlagsRoundTrip() throws {
        let json = #"{"hasSeenTransferIntro": true, "hasSeenTransferToSpendingIntro": true}"#

        let cache = try JSONDecoder().decode(AppCacheData.self, from: Data(json.utf8))
        let restored = try JSONDecoder().decode(AppCacheData.self, from: JSONEncoder().encode(cache))

        XCTAssertTrue(restored.hasSeenTransferIntro)
        XCTAssertTrue(restored.hasSeenTransferToSpendingIntro)
    }
}
