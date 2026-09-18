import Foundation

/// One result handed from a CoreBluetooth delegate callback to the thread blocked on it. The first
/// resolution wins, so a late callback can never overwrite a failure the waiter already acted on.
final class BLEOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    var isResolved: Bool {
        lock.withLock { result != nil }
    }

    func resolve(_ result: Result<Void, Error>) {
        let isFirst = lock.withLock {
            guard self.result == nil else { return false }
            self.result = result
            return true
        }
        if isFirst {
            semaphore.signal()
        }
    }

    /// Nil when nothing resolved it within `timeout`.
    func wait(timeout: TimeInterval) -> Result<Void, Error>? {
        if semaphore.wait(timeout: .now() + max(timeout, 0)) == .success {
            // Hand the permit back so a later wait on a resolved shot returns at once too.
            semaphore.signal()
        }
        return lock.withLock { result }
    }
}

/// The state of one Bluetooth link to a Jade, from being dialled until it is closed.
///
/// Every open creates a new instance with its own `generation`, so work queued for an earlier link to
/// the same device never lands on a newer one. Each setup step and each write registers a one-shot
/// waiter that a delegate callback resolves, and a drop or a close fails every waiter at once, so no
/// Rust thread stays blocked on a link that is gone. Free of CoreBluetooth types so it can be tested.
final class JadeBLELinkState: @unchecked Sendable {
    enum Step: Hashable, CaseIterable {
        case connect
        case services
        case characteristics
        case subscribe
        case write
        case disconnect
    }

    enum ReadOutcome: Equatable {
        case data(Data)
        case empty
        case down
    }

    let generation: UInt64

    private let lock = NSLock()
    private let notifications = BlockingQueue<Data>()
    private let closedSignal = BLEOneShot()
    private var waiters: [Step: BLEOneShot] = [:]
    private var linkUp = false
    private var ready = false
    private var closing = false
    private var dropReason: Error?
    private var negotiatedChunkSize: UInt32?
    private var completedWrites = 0

    init(generation: UInt64) {
        self.generation = generation
    }

    var isLinkUp: Bool {
        lock.withLock { linkUp }
    }

    var isReady: Bool {
        lock.withLock { ready }
    }

    var isClosing: Bool {
        lock.withLock { closing }
    }

    /// Ready, still connected and nobody is closing it.
    var isUsable: Bool {
        lock.withLock { ready && linkUp && !closing }
    }

    /// Nil until the link is ready.
    var chunkSize: UInt32? {
        lock.withLock { negotiatedChunkSize }
    }

    var writesCompleted: Int {
        lock.withLock { completedWrites }
    }

    /// Registers the waiter for `step`, failing any earlier waiter of the same step. On a closing or
    /// dropped link the waiter comes back already resolved, so nobody waits on a link that is gone.
    func begin(_ step: Step) -> BLEOneShot {
        let waiter = BLEOneShot()
        let (immediate, replaced): (Result<Void, Error>?, BLEOneShot?) = lock.withLock {
            if step == .disconnect, dropReason != nil {
                return (.success(()), nil)
            }
            if step != .disconnect, closing {
                return (.failure(JadeBLEError.closed), nil)
            }
            if step != .disconnect, let dropReason {
                return (.failure(dropReason), nil)
            }
            return (nil, waiters.updateValue(waiter, forKey: step))
        }
        replaced?.resolve(.failure(JadeBLEError.closed))
        if let immediate {
            waiter.resolve(immediate)
        }
        return waiter
    }

    /// Resolves the waiter of `step`. False when nobody is waiting any more, for a late callback.
    @discardableResult
    func resolve(_ step: Step, error: Error?) -> Bool {
        guard let waiter = lock.withLock({ waiters.removeValue(forKey: step) }) else { return false }
        waiter.resolve(error.map { .failure($0) } ?? .success(()))
        return true
    }

    /// Marks the link up when its connect is still awaited. False for a connect nobody waits for any
    /// more, which the caller has to cancel so the Jade is not left holding a connection.
    func markConnected() -> Bool {
        let waiter: BLEOneShot? = lock.withLock {
            guard !closing, dropReason == nil, let waiter = waiters.removeValue(forKey: .connect) else { return nil }
            linkUp = true
            return waiter
        }
        guard let waiter else { return false }
        waiter.resolve(.success(()))
        return true
    }

    /// Drops the waiter of `step` after it timed out, unless a newer waiter took its place.
    func abandon(_ step: Step, _ waiter: BLEOneShot) {
        lock.withLock {
            if waiters[step] === waiter {
                waiters[step] = nil
            }
        }
    }

    func markReady(chunkSize: UInt32) throws {
        try lock.withLock {
            if closing {
                throw JadeBLEError.closed
            }
            if let dropReason {
                throw dropReason
            }
            guard linkUp else { throw JadeBLEError.disconnected }
            ready = true
            negotiatedChunkSize = chunkSize
        }
    }

    /// Takes the link down and fails every waiter with `reason`; a disconnect waiter succeeds instead.
    /// Returns true when nobody was closing the link, so the drop came from outside the app.
    @discardableResult
    func markDown(reason: Error) -> Bool {
        let (pending, isExternal): ([Step: BLEOneShot], Bool) = lock.withLock {
            linkUp = false
            ready = false
            if dropReason == nil {
                dropReason = reason
            }
            let pending = waiters
            waiters.removeAll()
            return (pending, !closing)
        }
        notifications.fail()
        for (step, waiter) in pending {
            waiter.resolve(step == .disconnect ? .success(()) : .failure(reason))
        }
        return isExternal
    }

    /// Starts closing the link: it stops being ready, and every waiter but the disconnect one fails.
    /// False when a close is already under way.
    func beginClosing() -> Bool {
        let pending: [BLEOneShot]? = lock.withLock {
            guard !closing else { return nil }
            closing = true
            ready = false
            let pending = waiters.filter { $0.key != .disconnect }
            for step in pending.keys {
                waiters[step] = nil
            }
            return Array(pending.values)
        }
        guard let pending else { return false }
        notifications.fail()
        for waiter in pending {
            waiter.resolve(.failure(JadeBLEError.closed))
        }
        return true
    }

    func finishClosing() {
        closedSignal.resolve(.success(()))
    }

    /// Waits for a close that another caller started to finish.
    @discardableResult
    func waitUntilClosed(timeout: TimeInterval) -> Bool {
        closedSignal.wait(timeout: timeout) != nil
    }

    /// Clears what an earlier session left unread, when the link can be reused as it is.
    func reuseIfUsable() -> Bool {
        lock.withLock {
            guard ready, linkUp, !closing else { return false }
            notifications.clear()
            return true
        }
    }

    func recordWrite() {
        lock.withLock { completedWrites += 1 }
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        let isAccepting = lock.withLock { linkUp && !closing }
        guard isAccepting else { return }
        notifications.offer(data)
    }

    /// Waits up to `timeout` for a notification, then returns it joined with any queued behind it, in
    /// arrival order and untouched: frames are not aligned to notifications.
    func read(timeout: TimeInterval) -> ReadOutcome {
        if let first = notifications.poll(timeout: max(timeout, 0)) {
            let joined = notifications.drain().reduce(into: first) { $0.append($1) }
            return .data(joined)
        }
        let isDown = lock.withLock { !linkUp || closing }
        return isDown ? .down : .empty
    }
}
