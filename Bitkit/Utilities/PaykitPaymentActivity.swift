import Foundation

struct PaykitPaymentProofRefreshState {
    struct Request: Equatable {
        let id = UUID()
        let session: PubkyProfileManager.SignedInSession
    }

    private var pending: Request?

    mutating func invalidate(session: PubkyProfileManager.SignedInSession?) {
        pending = session.map { Request(session: $0) }
    }

    func request(session: PubkyProfileManager.SignedInSession?, isActive: Bool) -> Request? {
        guard isActive, let pending, pending.session == session else { return nil }
        return pending
    }

    mutating func complete(_ request: Request) {
        if pending == request { pending = nil }
    }

    mutating func discard(unlessSession session: PubkyProfileManager.SignedInSession?) {
        if pending?.session != session { pending = nil }
    }
}

@MainActor
final class PaykitPaymentActivity {
    enum DeferredWork: Hashable {
        case acceptance(identity: String, counterparty: String)
    }

    static let shared = PaykitPaymentActivity()

    private var payments: Set<UUID> = []
    private var idleWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var deferredOperations: [DeferredWork: @MainActor () async -> Void] = [:]
    private var deferredTasks: [DeferredWork: Task<Void, Never>] = [:]

    var isActive: Bool {
        !payments.isEmpty
    }

    func begin() -> UUID {
        let id = UUID()
        payments.insert(id)
        return id
    }

    func end(_ id: UUID) {
        payments.remove(id)
        guard payments.isEmpty else { return }
        let waiters = idleWaiters.values
        idleWaiters.removeAll()
        waiters.forEach { $0.finish() }
    }

    func waitUntilIdle() async throws {
        while isActive {
            try Task.checkCancellation()
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            idleWaiters[id] = continuation
            for await _ in stream {}
            idleWaiters.removeValue(forKey: id)
        }
        try Task.checkCancellation()
    }

    @discardableResult
    func runWhenIdle(_ key: DeferredWork, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        deferredOperations[key] = operation
        if let task = deferredTasks[key] { return task }
        let task = Task {
            do {
                try await waitUntilIdle()
            } catch {
                deferredOperations.removeValue(forKey: key)
                deferredTasks.removeValue(forKey: key)
                return
            }
            let operation = deferredOperations.removeValue(forKey: key)
            deferredTasks.removeValue(forKey: key)
            await operation?()
        }
        deferredTasks[key] = task
        return task
    }
}
