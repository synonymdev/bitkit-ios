@testable import Bitkit
import XCTest

final class AppCacheDataTests: XCTestCase {
    func testBackupWithRemovedBlocktankKeysStillDecodes() throws {
        let json = #"""
        {
            "hasSeenShopIntro": true,
            "hasSeenTransferIntro": true,
            "hasSeenTransferToSpendingIntro": true,
            "blocktankRefundAddress": {"address": "bcrt1refund", "index": 7},
            "lastUsedTags": ["coffee"]
        }
        """#

        let cache = try JSONDecoder().decode(AppCacheData.self, from: Data(json.utf8))

        XCTAssertTrue(cache.hasSeenShopIntro)
        XCTAssertEqual(cache.lastUsedTags, ["coffee"])
    }
}
