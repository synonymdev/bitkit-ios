import Foundation

/// Slim Bitcoin fee weather fetcher used inside the WidgetKit extension.
enum WeatherWidgetService {
    enum FetchError: Error {
        case invalidURL
        case unexpectedResponse
        case missingData
    }

    private static let baseUrl = "https://mempool.space/api"
    /// Average native segwit transaction size used to convert sats/vByte → total sats.
    private static let vbytesSize = 140

    static func cachedLatest() -> CachedWeather? {
        WeatherWidgetCache.loadLatest()
    }

    /// Returns the cached weather only while it's within the freshness TTL set by
    /// `WeatherWidgetCache.cacheFreshnessTTL`. The widget timeline uses this so it can fall
    /// back to its own fetch when the main app hasn't refreshed in a while.
    static func cachedLatestIfFresh() -> CachedWeather? {
        WeatherWidgetCache.loadLatestIfFresh()
    }

    static func latestWeather() async -> CachedWeather? {
        if let fresh = cachedLatestIfFresh() { return fresh }
        if let fresh = try? await fetchFreshLatest() { return fresh }
        return cachedLatest()
    }

    static func fetchFreshLatest() async throws -> CachedWeather {
        async let feesPromise = fetchRecommendedFees()
        async let pricesPromise = fetchPrices()
        async let percentilePromise = resolvePercentile()

        let fees = try await feesPromise
        let prices = await (try? pricesPromise) ?? [:]
        let percentile = try? await percentilePromise

        // USD is always used for the $1 "favorable" threshold, regardless of display currency.
        let usdRate = prices["USD"]
        let displayCurrency = WeatherCurrencyAppGroupStore.load()
        let displayRate = prices[displayCurrency] ?? usdRate
        let resolvedCurrency = prices[displayCurrency] != nil ? displayCurrency : WeatherCurrencyAppGroupStore.fallbackCode

        let midSatsPerVbyte = Double(fees.halfHourFee)
        let medianFeeSats = fees.halfHourFee * Self.vbytesSize

        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: midSatsPerVbyte,
            totalSats: medianFeeSats,
            usdPerBtc: usdRate,
            percentile: percentile
        )

        let fiatString = formatFiat(
            sats: medianFeeSats,
            currencyPerBtc: displayRate,
            currencyCode: resolvedCurrency
        )

        let entry = CachedWeather(
            condition: condition,
            currentFeeFiat: fiatString,
            currentFeeSats: medianFeeSats,
            nextBlockFee: fees.fastestFee
        )

        // Persist to the shared App Group cache. The main app will overwrite this on the next
        // foreground refresh; until then the next timeline tick within the TTL reuses our write.
        WeatherWidgetCache.saveLatest(entry)
        return entry
    }

    // MARK: - Percentile resolution

    /// Returns a cached `FeePercentile` if one is fresh (within `WeatherWidgetCache.percentileTTL`),
    /// otherwise fetches the 3-month history and caches the freshly computed percentile.
    private static func resolvePercentile() async throws -> FeePercentile {
        if let cached = WeatherWidgetCache.loadPercentile() {
            return cached
        }
        let history = try await fetchHistoricalFees()
        guard let percentile = FeePercentile(history: history) else {
            throw FetchError.missingData
        }
        WeatherWidgetCache.savePercentile(percentile)
        return percentile
    }

    // MARK: - Network

    private static func fetchRecommendedFees() async throws -> WireRecommendedFees {
        guard let url = URL(string: "\(baseUrl)/v1/fees/recommended") else {
            throw FetchError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.unexpectedResponse
        }
        return try JSONDecoder().decode(WireRecommendedFees.self, from: data)
    }

    /// Returns the BTC spot price map from mempool.space (currency code → unit price for 1 BTC).
    /// The endpoint reports a handful of fiat currencies (USD, EUR, GBP, CAD, CHF, AUD, JPY) plus
    /// a `time` field which is stripped here.
    private static func fetchPrices() async throws -> [String: Double] {
        guard let url = URL(string: "\(baseUrl)/v1/prices") else {
            throw FetchError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.unexpectedResponse
        }
        let raw = try JSONDecoder().decode([String: Double].self, from: data)
        return raw.filter { $0.key != "time" }
    }

    private static func fetchHistoricalFees() async throws -> [BlockFeeRates] {
        guard let url = URL(string: "\(baseUrl)/v1/mining/blocks/fee-rates/3m") else {
            throw FetchError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.unexpectedResponse
        }
        return try JSONDecoder().decode([BlockFeeRates].self, from: data)
    }

    // MARK: - Formatting

    /// Formats a satoshi amount in the user's selected display currency. Falls back to a "—"
    /// placeholder string formatted in the resolved currency when the rate is missing.
    private static func formatFiat(sats: Int, currencyPerBtc: Double?, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2

        guard let currencyPerBtc, currencyPerBtc > 0 else {
            let symbol = formatter.currencySymbol ?? currencyCode
            return "\(symbol) —"
        }

        let amount = Double(sats) / 100_000_000.0 * currencyPerBtc
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f \(currencyCode)", amount)
    }
}

// MARK: - Wire models

private struct WireRecommendedFees: Codable {
    let fastestFee: Int
    let halfHourFee: Int
    let hourFee: Int
    let economyFee: Int
    let minimumFee: Int
}
