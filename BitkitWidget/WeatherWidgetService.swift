import Foundation

/// Slim Bitcoin fee weather fetcher used inside the WidgetKit extension. Network/decoding is
/// delegated to `MempoolWeatherAPI` so the URL strings and wire shapes stay in one place.
enum WeatherWidgetService {
    enum FetchError: Error {
        case missingData
    }

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
        async let feesPromise = MempoolWeatherAPI.fetchRecommendedFees()
        async let pricesPromise = MempoolWeatherAPI.fetchPrices()
        async let percentilePromise = resolvePercentile()

        let fees = try await feesPromise
        let prices = await (try? pricesPromise) ?? [:]
        let percentile = try? await percentilePromise

        // USD is always used for the $1 "favorable" threshold, regardless of display currency.
        let usdRate = prices["USD"]
        let displayCurrency = WeatherCurrencyAppGroupStore.load()
        let displayRate = prices[displayCurrency] ?? usdRate
        let resolvedCurrency = prices[displayCurrency] != nil ? displayCurrency : WeatherCurrencyAppGroupStore.fallbackCode
        // Use the same backend symbol the app synced; the USD fallback path uses the "$" fallback.
        let resolvedSymbol = resolvedCurrency == displayCurrency
            ? WeatherCurrencyAppGroupStore.loadSymbol()
            : WeatherCurrencyAppGroupStore.fallbackSymbol

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
            currencyCode: resolvedCurrency,
            symbol: resolvedSymbol
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
        let history = try await MempoolWeatherAPI.fetchHistoricalFees()
        guard let percentile = FeePercentile(history: history) else {
            throw FetchError.missingData
        }
        WeatherWidgetCache.savePercentile(percentile)
        return percentile
    }

    // MARK: - Formatting

    /// Formats a satoshi amount in the user's selected display currency, reusing the in-app
    /// currency logic (`formatFiatAmount` + `formatFiatWithSymbol`) and the backend `symbol`
    /// synced through the App Group. Falls back to a "—" placeholder when the rate is missing.
    private static func formatFiat(sats: Int, currencyPerBtc: Double?, currencyCode: String, symbol: String) -> String {
        guard let currencyPerBtc, currencyPerBtc > 0 else {
            return formatFiatWithSymbol(formatted: "—", symbol: symbol, currencyCode: currencyCode, withSpace: true)
        }

        let amount = (Decimal(sats) / Decimal(100_000_000)) * Decimal(currencyPerBtc)
        return formatFiatWithSymbol(formatted: formatFiatAmount(amount), symbol: symbol, currencyCode: currencyCode, withSpace: true)
    }
}
