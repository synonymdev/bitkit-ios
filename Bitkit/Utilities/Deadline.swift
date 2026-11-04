import Foundation

/// Returns nil once `timeout` passes, without waiting for an operation that ignores cancellation. The operation is cancelled
/// either way.
func withDeadline<T>(_ timeout: Duration, _ operation: @escaping () async -> T) async -> T? {
    let (results, continuation) = AsyncStream<T?>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let work = Task { await continuation.yield(operation()) }
    let deadline = Task {
        try await Task.sleep(for: timeout)
        continuation.yield(nil)
    }
    defer {
        work.cancel()
        deadline.cancel()
        continuation.finish()
    }

    for await result in results {
        return result
    }
    return nil
}
