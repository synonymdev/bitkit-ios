import Foundation
import Observation

/// Singleton debug log for Trezor operations
/// Provides in-app timestamped logging for debugging BLE/THP issues
///
/// Uses a buffered approach: messages are accumulated off-main and
/// flushed to the observed `entries` property at a throttled interval to
/// avoid overwhelming SwiftUI during high-volume FFI callbacks.
@Observable
@MainActor
class TrezorDebugLog {
    static let shared = TrezorDebugLog()

    /// Observed entries — updated at most every `flushInterval`
    var entries: [String] = []

    private static let maxEntries = 300

    /// Minimum interval between flushes to @Published
    private static let flushInterval: TimeInterval = 0.25

    nonisolated(unsafe) private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Thread-safe buffer for incoming log messages
    nonisolated(unsafe) private let bufferLock = NSLock()
    nonisolated(unsafe) private var buffer: [String] = []
    nonisolated(unsafe) private var flushScheduled = false

    private init() {}

    /// Add a timestamped log entry.
    /// Can be called from any thread — messages are buffered and
    /// flushed to @Published on main at a throttled rate.
    nonisolated func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"

        bufferLock.lock()
        buffer.append(entry)
        let needsSchedule = !flushScheduled
        if needsSchedule {
            flushScheduled = true
        }
        bufferLock.unlock()

        if needsSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) {
                self.flushBuffer()
            }
        }
    }

    /// Flush buffered entries into the @Published array
    private func flushBuffer() {
        bufferLock.lock()
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        flushScheduled = false
        bufferLock.unlock()

        guard !pending.isEmpty else { return }

        entries.append(contentsOf: pending)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// Clear all log entries
    func clear() {
        bufferLock.lock()
        buffer.removeAll()
        bufferLock.unlock()
        entries.removeAll()
    }

    /// Copy all entries as a single string (chronological)
    func copyAll() -> String {
        entries.joined(separator: "\n")
    }
}
