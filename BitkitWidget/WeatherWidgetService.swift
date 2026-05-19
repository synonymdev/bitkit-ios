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

    static func fetchFreshLatest() async throws -> CachedWeather {
        async let feesPromise = fetchRecommendedFees()
        async let usdRatePromise = fetchUsdRate()
        async let percentilePromise = resolvePercentile()

        let fees = try await feesPromise
        let usdRate = try? await usdRatePromise
        let percentile = try? await percentilePromise

        let midSatsPerVbyte = Double(fees.halfHourFee)
        let medianFeeSats = fees.halfHourFee * Self.vbytesSize

        let condition = FeeCondition.evaluate(
            midSatsPerVbyte: midSatsPerVbyte,
            totalSats: medianFeeSats,
            usdPerBtc: usdRate,
            percentile: percentile
        )

        let fiatString = formatFiat(sats: medianFeeSats, usdPerBtc: usdRate)

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

    /// Returns USD spot price for 1 BTC, or nil on failure (fiat string will fall back to "—").
    private static func fetchUsdRate() async throws -> Double {
        guard let url = URL(string: "\(baseUrl)/v1/prices") else {
            throw FetchError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.unexpectedResponse
        }
        return try JSONDecoder().decode(WirePrices.self, from: data).USD
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

    /// Formats a satoshi amount to a USD string using a BTC/USD rate. Returns "$ —" if rate is missing.
    private static func formatFiat(sats: Int, usdPerBtc: Double?) -> String {
        guard let usdPerBtc, usdPerBtc > 0 else { return "$ —" }
        let usd = Double(sats) / 100_000_000.0 * usdPerBtc
        return String(format: "$ %.2f", usd)
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

private struct WirePrices: Codable {
    let USD: Double
}
