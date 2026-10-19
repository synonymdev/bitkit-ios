import Foundation

/// Thread-safe blocking queue for BLE notification data
final class BlockingQueue<T>: @unchecked Sendable {
    private var queue: [T] = []
    private let lock = NSCondition()
    private var failed = false

    func offer(_ item: T) {
        lock.lock()
        queue.append(item)
        lock.signal()
        lock.unlock()
    }

    func poll(timeout: TimeInterval) -> T? {
        lock.lock()
        defer { lock.unlock() }

        let deadline = Date().addingTimeInterval(timeout)

        while queue.isEmpty, !failed {
            if !lock.wait(until: deadline) {
                return nil
            }
        }

        if failed || queue.isEmpty {
            return nil
        }

        return queue.removeFirst()
    }

    func drain() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let items = queue
        queue.removeAll()
        return items
    }

    func clear() {
        lock.lock()
        queue.removeAll()
        failed = false
        lock.unlock()
    }

    func fail() {
        lock.lock()
        failed = true
        lock.broadcast()
        lock.unlock()
    }
}
