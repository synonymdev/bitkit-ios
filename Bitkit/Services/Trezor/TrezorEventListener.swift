import BitkitCore
import Foundation

/// Bridges bitkit-core's `EventListener` callback (invoked on a background thread by the
/// Rust watcher loop) onto the main actor so the ViewModel can update `@Observable` state.
///
/// Mirrors bitkit-android's `eventBridge` in `TrezorRepo`.
final class TrezorEventListener: EventListener, @unchecked Sendable {
    /// Forwards `(watcherId, event)` to a consumer on the main actor.
    private let onEventHandler: @MainActor (String, WatcherEvent) -> Void

    init(onEvent: @escaping @MainActor (String, WatcherEvent) -> Void) {
        onEventHandler = onEvent
    }

    func onEvent(watcherId: String, event: WatcherEvent) {
        let handler = onEventHandler
        Task { @MainActor in
            TrezorDebugLog.shared.log("[WATCHER] [\(watcherId)] \(event.logLabel)")
            handler(watcherId, event)
        }
    }
}

extension WatcherEvent {
    /// Short label for the debug log.
    var logLabel: String {
        switch self {
        case .transactionsChanged:
            return "transactionsChanged"
        case let .error(message):
            return "error: \(message)"
        case let .disconnected(message):
            return "disconnected: \(message)"
        case .reconnected:
            return "reconnected"
        }
    }
}
