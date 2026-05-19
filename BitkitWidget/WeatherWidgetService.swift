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

    static func fetchFreshLatest() async throws -> CachedWeather {
        async let feesPromise = fetchRecommendedFees()
        async let usdRatePromise = fetchUsdRate()

        let fees = try await feesPromise
        let usdRate = try? await usdRatePromise

        let medianSatsPerVbyte = fees.halfHourFee
        let nextBlockSatsPerVbyte = fees.fastestFee
        let medianFeeSats = medianSatsPerVbyte * Self.vbytesSize

        let fiatString = formatFiat(sats: medianFeeSats, usdPerBtc: usdRate)
        let condition = condition(forFastestSatsPerVbyte: nextBlockSatsPerVbyte)

        return CachedWeather(
            condition: condition,
            currentFeeFiat: fiatString,
            currentFeeSats: medianFeeSats,
            nextBlockFee: nextBlockSatsPerVbyte
        )
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

    // MARK: - Formatting / classification

    private static func formatFiat(sats: Int, usdPerBtc: Double?) -> String {
        guard let usdPerBtc, usdPerBtc > 0 else { return "$ —" }
        let usd = Double(sats) / 100_000_000.0 * usdPerBtc
        return String(format: "$ %.2f", usd)
    }

    /// Simple classification rule used inside the extension (we don't have access to the in-app
    /// historical percentile calculation here). Mirrors the spirit of the in-app thresholds:
    /// fast fee ≤ 5 sat/vB → good, ≥ 50 sat/vB → poor, otherwise average.
    private static func condition(forFastestSatsPerVbyte rate: Int) -> FeeCondition {
        if rate <= 5 { return .good }
        if rate >= 50 { return .poor }
        return .average
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
