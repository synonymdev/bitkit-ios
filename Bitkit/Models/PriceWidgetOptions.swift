import Foundation

/// Options for configuring the in-app and home-screen price widgets (shared via App Group).
///
struct PriceWidgetOptions: Codable, Equatable {
    var selectedPair: String = "BTC/USD"
    var selectedPeriod: GraphPeriod = .oneDay

    init(selectedPair: String = "BTC/USD", selectedPeriod: GraphPeriod = .oneDay) {
        self.selectedPair = selectedPair
        self.selectedPeriod = selectedPeriod
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPair
        case selectedPairs // legacy v60 key
        case selectedPeriod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let pair = try container.decodeIfPresent(String.self, forKey: .selectedPair) {
            selectedPair = pair
        } else if let legacyPairs = try container.decodeIfPresent([String].self, forKey: .selectedPairs),
                  let first = legacyPairs.first
        {
            selectedPair = first
        } else {
            selectedPair = "BTC/USD"
        }

        selectedPeriod = try container.decodeIfPresent(GraphPeriod.self, forKey: .selectedPeriod) ?? .oneDay
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedPair, forKey: .selectedPair)
        try container.encode(selectedPeriod, forKey: .selectedPeriod)
    }
}
