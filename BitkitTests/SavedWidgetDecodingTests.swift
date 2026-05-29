@testable import Bitkit
import XCTest

/// Locks in the v60 → v61 migration contract for `SavedWidget`: blobs persisted before the
/// small/wide size system existed have no `size` key and must decode as `.wide`, while v61 blobs
/// round-trip their size faithfully.
final class SavedWidgetDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> SavedWidget {
        try JSONDecoder().decode(SavedWidget.self, from: Data(json.utf8))
    }

    private func decodeArray(_ json: String) throws -> [SavedWidget] {
        try JSONDecoder().decode([SavedWidget].self, from: Data(json.utf8))
    }

    /// v60 blob (no `size` key) must default to `.wide`.
    func testDecode_LegacyBlobWithoutSize_DefaultsToWide() throws {
        let widget = try decode(#"{"type":"price"}"#)
        XCTAssertEqual(widget.type, .price)
        XCTAssertEqual(widget.size, .wide)
        XCTAssertNil(widget.optionsData)
    }

    /// v61 blob with an explicit size must decode that size.
    func testDecode_BlobWithSize_UsesStoredSize() throws {
        XCTAssertEqual(try decode(#"{"type":"blocks","size":"small"}"#).size, .small)
        XCTAssertEqual(try decode(#"{"type":"news","size":"wide"}"#).size, .wide)
    }

    /// A mixed array (legacy + v61 entries) must apply the per-entry rule independently.
    func testDecode_MixedArray_AppliesPerEntryDefault() throws {
        let widgets = try decodeArray(#"[{"type":"price","size":"small"},{"type":"news"},{"type":"weather","size":"wide"}]"#)
        XCTAssertEqual(widgets.map(\.type), [.price, .news, .weather])
        XCTAssertEqual(widgets.map(\.size), [.small, .wide, .wide])
    }

    /// Encoding then decoding must preserve type, size, and optionsData.
    func testRoundTrip_PreservesSize() throws {
        let optionsData = try JSONEncoder().encode(PriceWidgetOptions(selectedPair: "BTC/EUR", selectedPeriod: .oneWeek))
        let original = SavedWidget(type: .price, optionsData: optionsData, size: .small)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedWidget.self, from: encoded)

        XCTAssertEqual(decoded.type, .price)
        XCTAssertEqual(decoded.size, .small)
        XCTAssertEqual(decoded.optionsData, optionsData)
    }
}
