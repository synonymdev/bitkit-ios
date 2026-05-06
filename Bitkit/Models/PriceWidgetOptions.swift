import Foundation

/// Options for configuring the in-app and home-screen price widgets (shared via App Group for the extension).
///
/// `selectedPairs` is kept as an array for storage backwards-compatibility with v60. The v61 UI is
/// single-select and only ever reads/writes `[firstPair]`.
struct PriceWidgetOptions: Codable, Equatable {
    var selectedPairs: [String] = ["BTC/USD"]
    var selectedPeriod: GraphPeriod = .oneDay
}
