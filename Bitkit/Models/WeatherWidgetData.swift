import Foundation

/// Bitcoin fee weather condition (good/average/poor).
enum FeeCondition: String, Codable {
    case good
    case average
    case poor

    var titleKey: String {
        switch self {
        case .good: return "widgets__weather__condition__good__title"
        case .average: return "widgets__weather__condition__average__title"
        case .poor: return "widgets__weather__condition__poor__title"
        }
    }

    /// Single-word title used in the compact small widget where the full "Favorable Conditions"
    /// sentence doesn't fit.
    var shortTitleKey: String {
        switch self {
        case .good: return "widgets__weather__condition__good__short_title"
        case .average: return "widgets__weather__condition__average__short_title"
        case .poor: return "widgets__weather__condition__poor__short_title"
        }
    }

    var descriptionKey: String {
        switch self {
        case .good: return "widgets__weather__condition__good__description"
        case .average: return "widgets__weather__condition__average__description"
        case .poor: return "widgets__weather__condition__poor__description"
        }
    }

    var icon: String {
        switch self {
        case .good: return "☀️"
        case .average: return "⛅"
        case .poor: return "⛈️"
        }
    }
}

/// Persistable representation of the latest fee weather, shared between the main app and the
/// widget extension via the App Group. Strings are pre-formatted by `WeatherViewModel` so the
/// widget extension can render without re-running currency conversion.
struct CachedWeather: Codable, Equatable {
    let condition: FeeCondition
    /// Pre-formatted fiat string (e.g. "$ 0.52").
    let currentFeeFiat: String
    /// Median fee in sats (e.g. 520).
    let currentFeeSats: Int
    /// Next-block inclusion fee rate in sats/vByte (e.g. 6).
    let nextBlockFee: Int
}

/// App Group cache reader/writer used by both the main app and the widget extension.
enum WeatherWidgetCache {
    static let appGroupSuiteName = "group.bitkit"
    private static let latestKey = "weather_widget_latest_v1"
    private static let legacyStandardKey = "weather_widget_cache"

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    static func saveLatest(_ data: CachedWeather) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults().set(encoded, forKey: latestKey)
    }

    static func loadLatest() -> CachedWeather? {
        guard let data = defaults().data(forKey: latestKey),
              let decoded = try? JSONDecoder().decode(CachedWeather.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    /// One-time cleanup of the pre-App-Group cache that lived in `UserDefaults.standard`.
    static func legacyDropStandardSuiteCache() {
        UserDefaults.standard.removeObject(forKey: legacyStandardKey)
    }
}
