@testable import Bitkit
import XCTest

final class RNMigrationTagRetentionTests: XCTestCase {
    func testKeepsOnlyTagsWhoseActivityIsMissing() {
        let metadata = RNMetadata(
            tags: ["known": ["sent"], "missing": ["received"]],
            lastUsedTags: ["sent"]
        )

        let remaining = rnMetadataRetainingUnappliedTags(metadata, unappliedActivityIds: ["missing"])

        XCTAssertEqual(remaining?.tags, ["missing": ["received"]])
        XCTAssertNil(remaining?.lastUsedTags)
    }

    func testDropsMetadataWhenEveryTagApplied() {
        let metadata = RNMetadata(tags: ["known": ["sent"]], lastUsedTags: ["sent"])

        XCTAssertNil(rnMetadataRetainingUnappliedTags(metadata, unappliedActivityIds: []))
    }

    func testDropsMetadataWhenThereAreNoTags() {
        let metadata = RNMetadata(tags: nil, lastUsedTags: ["sent"])

        XCTAssertNil(rnMetadataRetainingUnappliedTags(metadata, unappliedActivityIds: ["missing"]))
    }
}
