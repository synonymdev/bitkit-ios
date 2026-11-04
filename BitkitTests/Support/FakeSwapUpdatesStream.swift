@testable import Bitkit
import BitkitCore
import Foundation

/// Stands in for bitkit-core's one swap updates stream, recording each start and stop in the order the stream takes them.
/// `startGate` holds the starts that reach it, when `holdsStarts` is set.
final class FakeSwapUpdatesStream: SwapUpdatesStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _startArrivals = 0
    let startGate = AsyncGate()
    var holdsStarts = false

    var isSwapEnabled: Bool {
        true
    }

    var calls: [String] {
        lock.withLock { _calls }
    }

    var startArrivals: Int {
        lock.withLock { _startArrivals }
    }

    func startUpdates(feeRateSatPerVb _: Double?, acceptZeroConf _: Bool) async throws {
        lock.withLock { _startArrivals += 1 }
        if holdsStarts {
            await startGate.wait()
        }
        lock.withLock { _calls.append("start") }
    }

    func stopUpdates() async {
        lock.withLock { _calls.append("stop") }
    }

    func events() -> AsyncStream<BoltzSwapEvent> {
        AsyncStream { $0.finish() }
    }
}
