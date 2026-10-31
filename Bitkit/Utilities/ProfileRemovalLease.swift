import Foundation

/// Keeps a live removal intent between confirmations while active work retains its own drain holder.
final class ProfileRemovalLease: @unchecked Sendable {
    let scope: ProfileOperationAdmission.Scope
    private let lock = NSLock()
    private let revokeRemoteAdmission: @Sendable () -> Void
    private let handlerID = UUID()
    private var retired = false
    private var active = false

    init(scope: ProfileOperationAdmission.Scope, revokeRemoteAdmission: @escaping @Sendable () -> Void) {
        self.scope = scope
        self.revokeRemoteAdmission = revokeRemoteAdmission
        scope.admission.onRevocation(of: scope, id: handlerID) { [weak self] in self?.retire() }
    }

    deinit { retire() }

    var canResume: Bool {
        lock.withLock { !retired && !active } && (try? scope.admission.validate(scope, access: .control)) != nil
    }

    func retire() {
        let releaseIdle = lock.withLock {
            guard !retired else { return false }
            retired = true
            return true
        }
        guard releaseIdle else { return }
        revokeRemoteAdmission()
        scope.admission.removeCancellationHandler(from: scope, id: handlerID)
        scope.admission.revoke(scope)
        scope.admission.release(scope)
    }

    func withOperation<T>(_ operation: () async throws -> T) async throws -> T {
        try lock.withLock {
            guard !retired, !active else { throw ProfileRemovalStore.StoreError.changed }
            active = true
        }
        defer { lock.withLock { active = false } }
        let work = try ProfileOperationAdmission.$current.withValue(scope) {
            try scope.admission.capture(access: .control)
        }
        defer { scope.admission.release(work) }
        return try await scope.admission.withScope(work, access: .control, operation)
    }
}
