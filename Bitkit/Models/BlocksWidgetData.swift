import Foundation

/// Persistable representation of the latest mined block, shared between the main app and the
/// widget extension via the App Group. Strings are pre-formatted by the main-app `BlocksService`
/// so the widget extension can render without re-running locale-sensitive formatting.
struct CachedBlock: Codable, Equatable {
    let height: String
    let time: String
    let date: String
    let transactionCount: String
    let size: String
    let fees: String
}

/// Cache reader/writer used by both the main app and the widget extension.
enum BlocksWidgetCache {
    static let appGroupSuiteName = "group.bitkit"
    private static let latestKey = "blocks_widget_latest_v1"
    private static let legacyStandardKey = "blocks_widget_cache"

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? .standard
    }

    static func saveLatest(_ block: CachedBlock) {
        guard let encoded = try? JSONEncoder().encode(block) else { return }
        defaults().set(encoded, forKey: latestKey)
    }

    static func loadLatest() -> CachedBlock? {
        guard let data = defaults().data(forKey: latestKey),
              let decoded = try? JSONDecoder().decode(CachedBlock.self, from: data)
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
