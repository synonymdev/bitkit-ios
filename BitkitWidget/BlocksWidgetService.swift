import Foundation

/// Slim Bitcoin Blocks fetcher used inside the WidgetKit extension.
///
/// Reads the latest `CachedBlock` from the App Group (written by the main app's `BlocksService`)
/// and falls back to a direct mempool.space fetch when the cache is empty. The cache itself is
/// owned by the main app; this service intentionally does not write back to it.
enum BlocksWidgetService {
    enum FetchError: Error {
        case invalidURL
        case unexpectedResponse
        case missingData
    }

    private static let baseUrl = "https://mempool.space/api"

    static func cachedLatest() -> CachedBlock? {
        BlocksWidgetCache.loadLatest()
    }

    static func fetchFreshLatest() async throws -> CachedBlock {
        guard let tipUrl = URL(string: "\(baseUrl)/blocks/tip/hash") else {
            throw FetchError.invalidURL
        }

        let (hashData, hashResponse) = try await URLSession.shared.data(from: tipUrl)
        guard let httpResponse = hashResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.unexpectedResponse
        }

        let hash = String(data: hashData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let blockUrl = URL(string: "\(baseUrl)/v1/block/\(hash)") else {
            throw FetchError.invalidURL
        }

        let (blockData, blockResponse) = try await URLSession.shared.data(from: blockUrl)
        guard let httpBlockResponse = blockResponse as? HTTPURLResponse, httpBlockResponse.statusCode == 200 else {
            throw FetchError.unexpectedResponse
        }

        let info = try JSONDecoder().decode(WireBlock.self, from: blockData)
        return Self.format(info)
    }

    private static func format(_ info: WireBlock) -> CachedBlock {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current

        let sizeKb = Double(info.size) / 1024

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .medium

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none

        let date = Date(timeIntervalSince1970: TimeInterval(info.timestamp))

        let formattedHeight = formatter.string(from: NSNumber(value: info.height)) ?? "\(info.height)"
        let formattedSize = "\(formatter.string(from: NSNumber(value: Int(sizeKb))) ?? "\(Int(sizeKb))") KB"
        let formattedTransactions = formatter.string(from: NSNumber(value: info.txCount)) ?? "\(info.txCount)"
        let totalFees = info.extras?.totalFees ?? 0
        let formattedFees = formatter.string(from: NSNumber(value: totalFees)) ?? "\(totalFees)"

        return CachedBlock(
            height: formattedHeight,
            time: timeFormatter.string(from: date),
            date: dateFormatter.string(from: date),
            transactionCount: formattedTransactions,
            size: formattedSize,
            fees: formattedFees
        )
    }
}

// MARK: - Wire models

/// Local mirror of the mempool `/api/v1/block/:hash` payload — kept private so the extension
/// stays small and decoupled from the main app's `BlockInfo`.
private struct WireBlock: Codable {
    let id: String
    let height: Int
    let timestamp: Int
    let txCount: Int
    let size: Int
    let weight: Int
    let extras: WireExtras?

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

private struct WireExtras: Codable {
    let totalFees: Int?
}
