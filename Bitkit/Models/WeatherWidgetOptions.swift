import Foundation

/// Single-select display metric used by the v61 Weather widget.
enum WeatherDisplayMetric: String, Codable, CaseIterable {
    case fiatFee
    case satsFee
    case nextBlockFee
}

/// Options for configuring the in-app and home-screen Weather widgets (shared via App Group).
struct WeatherWidgetOptions: Codable, Equatable {
    var selectedMetric: WeatherDisplayMetric = .fiatFee

    init(selectedMetric: WeatherDisplayMetric = .fiatFee) {
        self.selectedMetric = selectedMetric
    }

    private enum CodingKeys: String, CodingKey {
        case selectedMetric
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedMetric = try container.decodeIfPresent(WeatherDisplayMetric.self, forKey: .selectedMetric) ?? .fiatFee
    }
}
