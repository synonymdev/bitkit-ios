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

// MARK: - Classification algorithm

extension FeeCondition {
    static let usdGoodThreshold: Double = 1.0

    ///   - midSatsPerVbyte: current median fee rate (mempool `halfHourFee`, BitkitCore `fees.mid`).
    ///   - totalSats: `midSatsPerVbyte × 140 vBytes` — average native-segwit transaction cost.
    ///   - usdPerBtc: latest BTC/USD spot price (optional). When the resulting total fee in USD is
    ///     at or below `usdGoodThreshold`, the condition is always `.good`.
    ///   - percentile: 33rd/66th percentile of the last 3 months of median block fees. Optional —
    ///     if missing the function returns `.average`.
    static func evaluate(
        midSatsPerVbyte: Double,
        totalSats: Int,
        usdPerBtc: Double?,
        percentile: FeePercentile?
    ) -> FeeCondition {
        if let usdPerBtc, usdPerBtc > 0 {
            let usdValue = Double(totalSats) / 100_000_000 * usdPerBtc
            if usdValue <= usdGoodThreshold { return .good }
        }
        guard let percentile else { return .average }
        if midSatsPerVbyte <= percentile.lowThreshold { return .good }
        if midSatsPerVbyte >= percentile.highThreshold { return .poor }
        return .average
    }
}

/// Block fee rates structure from mempool.space `/v1/mining/blocks/fee-rates/3m`. Only
/// `avgFee_50` (median per-block fee) is consumed for percentile classification, but the other
/// fields are decoded for compatibility with the wire response.
struct BlockFeeRates: Codable {
    let avgHeight: Int
    let timestamp: Int
    let avgFee_0: Double
    let avgFee_10: Double
    let avgFee_25: Double
    let avgFee_50: Double
    let avgFee_75: Double
    let avgFee_90: Double
    let avgFee_100: Double
}

/// 33rd / 66th percentile thresholds computed from a 3-month window of median block fees.
struct FeePercentile: Codable, Equatable {
    let lowThreshold: Double
    let highThreshold: Double

    static let percentileLow = 0.33
    static let percentileHigh = 0.66

    init(lowThreshold: Double, highThreshold: Double) {
        self.lowThreshold = lowThreshold
        self.highThreshold = highThreshold
    }

    /// Computes percentiles from a raw history. Returns `nil` if `history` is empty so callers
    /// can fall back to a default classification.
    init?(history: [BlockFeeRates]) {
        guard !history.isEmpty else { return nil }
        let sorted = history.map(\.avgFee_50).sorted()
        let lowIndex = min(sorted.count - 1, Int(Double(sorted.count) * Self.percentileLow))
        let highIndex = min(sorted.count - 1, Int(Double(sorted.count) * Self.percentileHigh))
        lowThreshold = sorted[lowIndex]
        highThreshold = sorted[highIndex]
    }
}

// MARK: - Cached weather payload

struct CachedWeather: Codable, Equatable {
    let condition: FeeCondition
    /// Pre-formatted fiat string (e.g. "$ 0.52").
    let currentFeeFiat: String
    /// Median fee in sats (e.g. 520).
    let currentFeeSats: Int
    /// Next-block inclusion fee rate in sats/vByte (e.g. 6).
    let nextBlockFee: Int
}

/// App Group entry pairing a cached `FeePercentile` with the time it was written, so the
/// widget extension can apply a TTL without refetching the 3-month history on every refresh.
struct CachedFeePercentile: Codable, Equatable {
    let percentile: FeePercentile
    let timestamp: Date
}

/// App Group cache reader/writer used by both the main app and the widget extension.
enum WeatherWidgetCache {
    static let appGroupSuiteName = "group.bitkit"
    private static let latestKey = "weather_widget_latest_v1"
    private static let latestTimestampKey = "weather_widget_latest_timestamp_v1"
    private static let percentileKey = "weather_widget_percentile_v1"
    private static let legacyStandardKey = "weather_widget_cache"

    /// How long the cached percentile is considered fresh.
    static let percentileTTL: TimeInterval = 30 * 60

    /// How long the cached `CachedWeather` is considered authoritative. Beyond this the OS
    /// widget falls back to its own fetch so it stays useful between app sessions.
    static let cacheFreshnessTTL: TimeInterval = 10 * 60

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    static func saveLatest(_ data: CachedWeather, now: Date = Date()) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        let store = defaults()
        store.set(encoded, forKey: latestKey)
        store.set(now.timeIntervalSince1970, forKey: latestTimestampKey)
    }

    /// Returns whatever's cached, regardless of age. Used by the in-app stale-while-revalidate
    /// flow that displays cached data immediately and refreshes in the background.
    static func loadLatest() -> CachedWeather? {
        guard let data = defaults().data(forKey: latestKey),
              let decoded = try? JSONDecoder().decode(CachedWeather.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    /// Returns the cached value only when its sibling timestamp is within
    /// `cacheFreshnessTTL`. Used by the OS widget timeline so it can decide whether to fall
    /// back to its own fetch when the main app hasn't refreshed in a while.
    static func loadLatestIfFresh(now: Date = Date()) -> CachedWeather? {
        guard let cached = loadLatest() else { return nil }
        let timestamp = defaults().double(forKey: latestTimestampKey)
        guard timestamp > 0, now.timeIntervalSince1970 - timestamp <= cacheFreshnessTTL else {
            return nil
        }
        return cached
    }

    static func savePercentile(_ percentile: FeePercentile, now: Date = Date()) {
        let entry = CachedFeePercentile(percentile: percentile, timestamp: now)
        guard let encoded = try? JSONEncoder().encode(entry) else { return }
        defaults().set(encoded, forKey: percentileKey)
    }

    /// Returns the cached percentile only when it's within the TTL window.
    static func loadPercentile(now: Date = Date()) -> FeePercentile? {
        guard let data = defaults().data(forKey: percentileKey),
              let entry = try? JSONDecoder().decode(CachedFeePercentile.self, from: data)
        else {
            return nil
        }
        guard now.timeIntervalSince(entry.timestamp) <= percentileTTL else { return nil }
        return entry.percentile
    }

    /// One-time cleanup of the pre-App-Group cache that lived in `UserDefaults.standard`.
    static func legacyDropStandardSuiteCache() {
        UserDefaults.standard.removeObject(forKey: legacyStandardKey)
    }
}
