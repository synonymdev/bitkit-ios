import Foundation

/// The wake ids this install has taken on, kept in the `group.bitkit` app group so the app and the notification extension
/// share them. A wake is delivered at least once and can reach both, so whoever claims an id first does its work.
final class WakeSeenStore {
    static let maxEntries = 500
    /// How long an id is kept after its deadline, for clocks that disagree with the gateway's.
    static let retentionAfterDeadlineSecs: UInt64 = 3600
    /// How long an id with no deadline is kept.
    static let retentionWithoutDeadlineSecs: UInt64 = 86400

    private let fileURL: URL
    private let lockURL: URL

    init(directory: URL = Env.appStorageUrl.appendingPathComponent("wake", isDirectory: true)) {
        fileURL = directory.appendingPathComponent("seen-wakes.json")
        lockURL = directory.appendingPathComponent("seen-wakes.lock")
    }

    /// Records `id` and returns true, or returns false when this process or another already recorded it. When the store
    /// cannot be used the wake is let through, since dropping one loses more than doing its work twice.
    func claim(id: String, deadline: UInt64?, now: UInt64 = WakeTimestamp.now) -> Bool {
        let expiresAt = deadline.map { $0 + Self.retentionAfterDeadlineSecs } ?? now + Self.retentionWithoutDeadlineSecs
        do {
            return try withExclusiveLock {
                var entries = loadEntries().filter { $0.value > now }
                guard entries[id] == nil else { return false }
                let overflow = entries.count + 1 - Self.maxEntries
                if overflow > 0 {
                    for oldest in entries.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                        entries.removeValue(forKey: oldest.key)
                    }
                }
                entries[id] = expiresAt
                try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
                return true
            }
        } catch {
            Logger.warn("Wake dedupe store unavailable: \(error)", context: "Wake")
            return true
        }
    }

    private func loadEntries() -> [String: UInt64] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: UInt64].self, from: data)) ?? [:]
    }

    /// `flock` on a lock file beside the store, which holds across the app and extension processes.
    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
