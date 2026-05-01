import Foundation
import WidgetKit

/// Service for fetching and caching Bitcoin block data
class BlocksService {
    static let shared = BlocksService()

    /// WidgetKit `kind` for the home screen blocks widget (keep in sync with `BitkitBlocksWidget`).
    static let blocksHomeScreenWidgetKind = "BitkitBlocksWidget"

    private static let appGroupSuiteName = "group.bitkit"
    private let cacheKey = "blocks_widget_cache"
    private let baseUrl = "https://mempool.space/api"
    private let refreshInterval: TimeInterval = 2 * 60 // 2 minutes

    private init() {}

    /// Fetches the latest block data using stale-while-revalidate strategy
    /// - Parameter returnCachedImmediately: If true, returns cached data immediately if available
    /// - Returns: Block data
    /// - Throws: URLError or decoding error
    @discardableResult
    func fetchBlockData(returnCachedImmediately: Bool = true) async throws -> BlockData {
        // If we want cached data and it exists, return it immediately
        if returnCachedImmediately, let cachedData = getCachedData() {
            // Start fresh fetch in background to update cache (don't await)
            Task {
                do {
                    try await fetchFreshData()
                    // Cache will be updated automatically in fetchFreshData
                } catch {
                    // Silent failure for background updates
                    print("Background blocks data update failed: \(error)")
                }
            }
            return cachedData
        }

        // No cache available or cache not requested - fetch fresh data
        return try await fetchFreshData()
    }

    /// Fetches fresh data from API (always hits the network)
    @discardableResult
    private func fetchFreshData() async throws -> BlockData {
        // First get the tip hash
        guard let tipUrl = URL(string: "\(baseUrl)/blocks/tip/hash") else {
            throw URLError(.badURL)
        }

        let (hashData, hashResponse) = try await URLSession.shared.data(from: tipUrl)

        // Validate HTTP response
        guard let httpResponse = hashResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let hash = String(data: hashData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Now get the block info
        guard let blockUrl = URL(string: "\(baseUrl)/block/\(hash)") else {
            throw URLError(.badURL)
        }

        let (blockData, blockResponse) = try await URLSession.shared.data(from: blockUrl)

        // Validate HTTP response
        guard let httpBlockResponse = blockResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpBlockResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        do {
            let decoder = JSONDecoder()
            let blockInfo = try decoder.decode(BlockInfo.self, from: blockData)
            let formattedData = formatBlockInfo(blockInfo)

            // Cache the data
            cacheData(formattedData)

            return formattedData
        } catch {
            throw error
        }
    }

    /// Caches block data to the App Group `UserDefaults` (shared with the widget extension).
    /// - Parameter data: Block data to cache
    func cacheData(_ data: BlockData) {
        do {
            let encoder = JSONEncoder()
            let encoded = try encoder.encode(data)
            if let group = UserDefaults(suiteName: Self.appGroupSuiteName) {
                group.set(encoded, forKey: cacheKey)
            } else {
                UserDefaults.standard.set(encoded, forKey: cacheKey)
            }
            reloadBlocksHomeScreenWidgetIfNeeded()
        } catch {
            // Handle silently
        }
    }

    /// Retrieves cached block data
    /// - Returns: Block data if available
    func getCachedData() -> BlockData? {
        if let group = UserDefaults(suiteName: Self.appGroupSuiteName),
           let data = group.data(forKey: cacheKey),
           let decoded = Self.decodeCachedBlockData(data)
        {
            return decoded
        }

        // One-time migration from pre–App Group cache
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = Self.decodeCachedBlockData(data)
        {
            cacheData(decoded)
            UserDefaults.standard.removeObject(forKey: cacheKey)
            return decoded
        }

        return nil
    }

    private static func decodeCachedBlockData(_ data: Data) -> BlockData? {
        try? JSONDecoder().decode(BlockData.self, from: data)
    }

    private func reloadBlocksHomeScreenWidgetIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: Self.blocksHomeScreenWidgetKind)
    }

    /// Formats raw block info into display-friendly format
    /// - Parameter blockInfo: Raw block info from API
    /// - Returns: Formatted block data
    private func formatBlockInfo(_ blockInfo: BlockInfo) -> BlockData {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current

        let difficulty = (blockInfo.difficulty / 1_000_000_000_000).formatted(.number.precision(.fractionLength(2)))
        let size = Double(blockInfo.size) / 1024
        let weight = Double(blockInfo.weight) / 1024 / 1024

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
        let formattedSize = "\(formatter.string(from: NSNumber(value: Int(size))) ?? "\(Int(size))") KB"
        let formattedTransactions = formatter.string(from: NSNumber(value: blockInfo.txCount)) ?? "\(blockInfo.txCount)"
        let formattedWeight = "\(formatter.string(from: NSNumber(value: weight)) ?? "\(weight)") MWU"

        return BlockData(
            hash: blockInfo.id,
            difficulty: difficulty,
            size: formattedSize,
            weight: formattedWeight,
            height: formattedHeight,
            time: time,
            date: dateString,
            transactionCount: formattedTransactions,
            merkleRoot: blockInfo.merkleRoot
        )
    }
}

/// Raw block info model from mempool.space API
struct BlockInfo: Codable {
    let id: String
    let height: Int
    let timestamp: Int
    let txCount: Int
    let size: Int
    let weight: Int
    let difficulty: Double
    let merkleRoot: String

    enum CodingKeys: String, CodingKey {
        case id
        case height
        case timestamp
        case txCount = "tx_count"
        case size
        case weight
        case difficulty
        case merkleRoot = "merkle_root"
    }
}

/// Formatted block data for display
struct BlockData: Codable {
    let hash: String
    let difficulty: String
    let size: String
    let weight: String
    let height: String
    let time: String
    let date: String
    let transactionCount: String
    let merkleRoot: String
}
