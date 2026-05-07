import Foundation

/// Service for fetching and caching the latest mined Bitcoin block.
///
/// Writes the result to the App Group cache (`BlocksWidgetCache`) so the WidgetKit extension
/// can surface the same data, and triggers a timeline reload on the home-screen widget after
/// a successful fresh fetch.
class BlocksService {
    static let shared = BlocksService()
    private let baseUrl = "https://mempool.space/api"
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    private init() {
        BlocksWidgetCache.legacyDropStandardSuiteCache()
    }

    /// Fetches the latest block data using stale-while-revalidate strategy.
    /// - Parameter returnCachedImmediately: If true, returns cached data immediately if available.
    @discardableResult
    func fetchBlockData(returnCachedImmediately: Bool = true) async throws -> CachedBlock {
        if returnCachedImmediately, let cachedData = getCachedData() {
            // Background refresh; cache is updated automatically inside fetchFreshData.
            Task {
                do {
                    try await fetchFreshData()
                } catch {
                    print("Background blocks data update failed: \(error)")
                }
            }
            return cachedData
        }

        return try await fetchFreshData()
    }

    /// Fetches fresh data from the mempool API.
    @discardableResult
    private func fetchFreshData() async throws -> CachedBlock {
        guard let tipUrl = URL(string: "\(baseUrl)/blocks/tip/hash") else {
            throw URLError(.badURL)
        }

        let (hashData, hashResponse) = try await URLSession.shared.data(from: tipUrl)

        guard let httpResponse = hashResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw URLError(.badServerResponse)
        }

        let hash = String(data: hashData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // The v1 endpoint returns the same fields as the legacy one plus an `extras` block with `totalFees`.
        guard let blockUrl = URL(string: "\(baseUrl)/v1/block/\(hash)") else {
            throw URLError(.badURL)
        }

        let (blockData, blockResponse) = try await URLSession.shared.data(from: blockUrl)

        guard let httpBlockResponse = blockResponse as? HTTPURLResponse,
              httpBlockResponse.statusCode == 200
        else {
            throw URLError(.badServerResponse)
        }

        let blockInfo = try JSONDecoder().decode(BlockInfo.self, from: blockData)
        let formattedData = formatBlockInfo(blockInfo)

        cacheData(formattedData)
        BlocksHomeScreenWidgetOptionsStore.reloadHomeScreenWidgetIfNeeded()

        return formattedData
    }

    /// Caches block data to the App Group so the WidgetKit extension can read it.
    func cacheData(_ data: CachedBlock) {
        BlocksWidgetCache.saveLatest(data)
    }

    /// Retrieves cached block data from the App Group.
    func getCachedData() -> CachedBlock? {
        BlocksWidgetCache.loadLatest()
    }

    /// Formats raw block info into display-friendly format.
    private func formatBlockInfo(_ blockInfo: BlockInfo) -> CachedBlock {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current

        let sizeKb = Double(blockInfo.size) / 1024

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .medium

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: TimeInterval(blockInfo.timestamp))
        let time = timeFormatter.string(from: date)
        let dateString = dateFormatter.string(from: date)

        let formattedHeight = formatter.string(from: NSNumber(value: blockInfo.height)) ?? "\(blockInfo.height)"
        let formattedSize = "\(formatter.string(from: NSNumber(value: Int(sizeKb))) ?? "\(Int(sizeKb))") KB"
        let formattedTransactions = formatter.string(from: NSNumber(value: blockInfo.txCount)) ?? "\(blockInfo.txCount)"

        let totalFeesSats = blockInfo.extras?.totalFees ?? 0
        let formattedFees = formatter.string(from: NSNumber(value: totalFeesSats)) ?? "\(totalFeesSats)"

        return CachedBlock(
            height: formattedHeight,
            time: time,
            date: dateString,
            transactionCount: formattedTransactions,
            size: formattedSize,
            fees: formattedFees
        )
    }
}

/// Raw block info model from mempool.space API (`/api/v1/block/:hash`).
struct BlockInfo: Codable {
    let id: String
    let height: Int
    let timestamp: Int
    let txCount: Int
    let size: Int
    let weight: Int
    let extras: Extras?

    struct Extras: Codable {
        let totalFees: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case height
        case timestamp
        case txCount = "tx_count"
        case size
        case weight
        case extras
    }
}
