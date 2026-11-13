import Foundation

/// Returns nil once `timeout` passes, without waiting for an operation that ignores cancellation. The operation is cancelled
/// either way.
func withDeadline<T>(_ timeout: Duration, _ operation: @escaping () async -> T) async -> T? {
    await withDeadline(until: { try await Task.sleep(for: timeout) }, operation)
}

/// Returns nil once `deadline` returns, like `withDeadline(_:_:)` with a deadline other than a clock's.
func withDeadline<T>(until deadline: @escaping () async throws -> Void, _ operation: @escaping () async -> T) async -> T? {
    let (results, continuation) = AsyncStream<T?>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let work = Task { await continuation.yield(operation()) }
    let deadlineTask = Task {
        try await deadline()
        continuation.yield(nil)
    }
    defer {
        work.cancel()
        deadlineTask.cancel()
        continuation.finish()
    }

    for await result in results {
        return result
    }
    return nil
}
