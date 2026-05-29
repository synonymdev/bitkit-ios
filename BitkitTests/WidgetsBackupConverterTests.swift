@testable import Bitkit
import XCTest

/// Locks in the backup contract for widget size: v61 sizes must survive an export → import
/// round-trip, exports must carry a `size` field, and backups predating the field (Android /
/// pre-v61 iOS) must fall back to the per-type default rather than blanket `.wide`.
final class WidgetsBackupConverterTests: XCTestCase {
    private func widgetsArray(_ androidFormat: [String: Any]) throws -> [[String: Any]] {
        return try XCTUnwrap(androidFormat["widgets"] as? [[String: Any]])
    }

    /// Export → import preserves type, size, and order for a mix of small/wide widgets.
    func testRoundTrip_PreservesSizeAndOrder() throws {
        let original: [SavedWidget] = [
            SavedWidget(type: .news, size: .wide),
            SavedWidget(type: .blocks, size: .small),
            SavedWidget(type: .weather, size: .small),
            SavedWidget(type: .price, size: .wide),
        ]

        let android = try WidgetsBackupConverter.convertToAndroidFormat(savedWidgets: original)
        let restored = try WidgetsBackupConverter.convertFromAndroidFormat(jsonDict: android)

        XCTAssertEqual(restored.map(\.type), original.map(\.type))
        XCTAssertEqual(restored.map(\.size), original.map(\.size))
    }

    /// Each exported entry carries its size as a raw string.
    func testExport_WritesSizeField() throws {
        let android = try WidgetsBackupConverter.convertToAndroidFormat(savedWidgets: [
            SavedWidget(type: .blocks, size: .small),
            SavedWidget(type: .news, size: .wide),
        ])

        let entries = try widgetsArray(android)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["size"] as? String, "small")
        XCTAssertEqual(entries[1]["size"] as? String, "wide")
    }

    /// Entries with no `size` (Android / pre-v61 backups) fall back to the per-type default.
    func testImport_MissingSize_FallsBackToPerTypeDefault() throws {
        let json: [String: Any] = [
            "widgets": [
                ["type": "BLOCK", "position": 0], // -> blocks, default .small
                ["type": "PRICE", "position": 1], // -> price, default .wide
                ["type": "WEATHER", "position": 2], // -> weather, default .small
            ],
        ]

        let restored = try WidgetsBackupConverter.convertFromAndroidFormat(jsonDict: json)

        XCTAssertEqual(restored.map(\.type), [.blocks, .price, .weather])
        XCTAssertEqual(restored.map(\.size), [.small, .wide, .small])
    }
}
