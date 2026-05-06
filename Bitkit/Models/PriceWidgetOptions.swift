import Foundation

/// Options for configuring the in-app and home-screen price widgets (shared via App Group for the extension).
struct PriceWidgetOptions: Codable, Equatable {
    var selectedPairs: [String] = ["BTC/USD"]
    var selectedPeriod: GraphPeriod = .oneDay
}
