import BitkitCore
import Foundation

/// What a delivery of a wake id should do.
enum WakeClaim: Equatable {
    /// The first delivery: do the work and acknowledge it.
    case new
    /// The work is running or done here or in the other process, and needs nothing more.
    case taken
    /// The work is done but its acknowledgement did not reach the gateway: send only that again.
    case unacknowledged(WakeAckOutcome)
}

/// The wake ids this install has taken on, kept in the `group.bitkit` app group so the app and the notification extension
/// share them. A wake is delivered at least once and can reach both, so whoever claims an id first does its work.
final class WakeSeenStore {
    static let maxEntries = 500
    /// How long an id is kept after its deadline, for clocks that disagree with the gateway's.
    static let retentionAfterDeadlineSecs: UInt64 = 3600
    /// How long an id with no deadline is kept.
    static let retentionWithoutDeadlineSecs: UInt64 = 86400

    private struct Entry: Codable {
        let expiresAt: UInt64
        /// Set once the work is done, while its acknowledgement has not reached the gateway.
        var unacknowledgedOutcome: String?
    }

    private let fileURL: URL
    private let lockURL: URL

    init(directory: URL = Env.appStorageUrl.appendingPathComponent("wake", isDirectory: true)) {
        fileURL = directory.appendingPathComponent("seen-wakes.json")
        lockURL = directory.appendingPathComponent("seen-wakes.lock")
    }

    /// Records `id` as taken on and returns `.new`, or says what an earlier delivery left to do. When the store cannot be
    /// used the wake is let through, since dropping one loses more than doing its work twice.
    func claim(id: String, deadline: UInt64?, now: UInt64 = WakeTimestamp.now) -> WakeClaim {
        let expiresAt = deadline.map { WakeTimestamp.saturatingAdd($0, Self.retentionAfterDeadlineSecs) }
            ?? WakeTimestamp.saturatingAdd(now, Self.retentionWithoutDeadlineSecs)
        do {
            return try update { entries in
                entries = entries.filter { $0.value.expiresAt > now }
                if let entry = entries[id] {
                    return entry.unacknowledgedOutcome.flatMap(WakeAckOutcome.init(storedName:)).map(WakeClaim.unacknowledged) ?? .taken
                }
                let overflow = entries.count + 1 - Self.maxEntries
                if overflow > 0 {
                    for oldest in entries.sorted(by: { $0.value.expiresAt < $1.value.expiresAt }).prefix(overflow) {
                        entries.removeValue(forKey: oldest.key)
                    }
                }
                entries[id] = Entry(expiresAt: expiresAt)
                return .new
            }
        } catch {
            Logger.warn("Wake dedupe store unavailable: \(error)", context: "Wake")
            return .new
        }
    }

    /// Records that the work for `id` is done with `outcome` and still has to be acknowledged.
    func recordUnacknowledged(id: String, outcome: WakeAckOutcome) {
        setUnacknowledgedOutcome(outcome.storedName, id: id)
    }

    /// Records that the gateway has the acknowledgement for `id`.
    func recordAcknowledged(id: String) {
        setUnacknowledgedOutcome(nil, id: id)
    }

    private func setUnacknowledgedOutcome(_ outcome: String?, id: String) {
        do {
            try update { entries in
                entries[id]?.unacknowledgedOutcome = outcome
            }
        } catch {
            Logger.warn("Wake dedupe store unavailable: \(error)", context: "Wake")
        }
    }

    /// Loads the entries, lets `body` change them and writes them back, under the lock.
    @discardableResult
    private func update<T>(_ body: (inout [String: Entry]) -> T) throws -> T {
        try withExclusiveLock {
            var entries = loadEntries()
            let result = body(&entries)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            return result
        }
    }

    private func loadEntries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
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

private extension WakeAckOutcome {
    var storedName: String {
        switch self {
        case .handled: "handled"
        case .noHandler: "no_handler"
        case .failed: "failed"
        }
    }

    init?(storedName: String) {
        switch storedName {
        case "handled": self = .handled
        case "no_handler": self = .noHandler
        case "failed": self = .failed
        default: return nil
        }
    }
}
