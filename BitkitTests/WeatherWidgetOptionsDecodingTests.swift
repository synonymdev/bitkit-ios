@testable import Bitkit
import XCTest

/// Locks in the v60 → v61 upgrade contract for `WeatherWidgetOptions`. Users with stored options
/// from the four-toggle layout must keep the metric they were using; new blobs round-trip
/// cleanly; missing/garbage blobs fall back to the default `.fiatFee`.
final class WeatherWidgetOptionsDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> WeatherWidgetOptions {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(WeatherWidgetOptions.self, from: data)
    }

    // MARK: - v61 (new) shape

    func testDecode_NewSelectedMetricKeyWins() throws {
        let options = try decode(#"{"selectedMetric":"nextBlockFee"}"#)
        XCTAssertEqual(options.selectedMetric, .nextBlockFee)
    }

    func testDecode_NewSelectedMetricFiatFee() throws {
        let options = try decode(#"{"selectedMetric":"fiatFee"}"#)
        XCTAssertEqual(options.selectedMetric, .fiatFee)
    }

    func testDecode_NewSelectedMetricSatsFee() throws {
        let options = try decode(#"{"selectedMetric":"satsFee"}"#)
        XCTAssertEqual(options.selectedMetric, .satsFee)
    }

    // MARK: - v60 (legacy) shape

    func testDecode_LegacyShowNextBlockFeeOnly_MapsToNextBlock() throws {
        let options = try decode(
            #"{"showStatus":true,"showText":true,"showMedian":false,"showNextBlockFee":true}"#
        )
        XCTAssertEqual(options.selectedMetric, .nextBlockFee)
    }

    func testDecode_LegacyShowMedianOnly_MapsToFiat() throws {
        let options = try decode(
            #"{"showStatus":true,"showText":true,"showMedian":true,"showNextBlockFee":false}"#
        )
        XCTAssertEqual(options.selectedMetric, .fiatFee)
    }

    func testDecode_LegacyBothMedianAndNextBlock_PrefersFiat() throws {
        // Old default had both visible; pick the fee metric (fiat) we now show as the v61 default.
        let options = try decode(
            #"{"showStatus":true,"showText":true,"showMedian":true,"showNextBlockFee":true}"#
        )
        XCTAssertEqual(options.selectedMetric, .fiatFee)
    }

    func testDecode_LegacyAllFalse_FallsBackToFiat() throws {
        let options = try decode(
            #"{"showStatus":false,"showText":false,"showMedian":false,"showNextBlockFee":false}"#
        )
        XCTAssertEqual(options.selectedMetric, .fiatFee)
    }

    // MARK: - Missing / unknown

    func testDecode_EmptyObject_FallsBackToFiat() throws {
        let options = try decode("{}")
        XCTAssertEqual(options.selectedMetric, .fiatFee)
    }

    func testDecode_UnknownMetricValue_Throws() {
        XCTAssertThrowsError(try decode(#"{"selectedMetric":"bogus"}"#))
    }

    // MARK: - Round-trip

    func testEncodeRoundtrip_OnlyWritesSelectedMetric() throws {
        let original = WeatherWidgetOptions(selectedMetric: .satsFee)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WeatherWidgetOptions.self, from: data)
        XCTAssertEqual(decoded, original)

        // The serialized blob must not carry the obsolete legacy keys forward.
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(jsonObject?.keys.sorted(), ["selectedMetric"])
    }
}
