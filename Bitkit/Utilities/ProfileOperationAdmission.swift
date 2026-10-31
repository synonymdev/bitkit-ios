import Foundation

/// Tracks complete profile operations, including their local tails, without holding a mutex across suspension.
/// A persisted removal record is an obligation; only a live reservation can authorize remote cleanup.
final class ProfileOperationAdmission: @unchecked Sendable {
    enum Access {
        case authenticated
        case local
        case control
    }

    enum Kind {
        case ordinary
        case sessionTransition
        case removal
        case localRecovery
        case walletWipe
    }

    struct Scope: Sendable {
        let admission: ProfileOperationAdmission
        fileprivate let id: UUID
    }

    struct Generation: Equatable, Sendable {
        fileprivate let live: UUID
        fileprivate let stored: UUID
    }

    private struct WalletOperationScope: Sendable {
        let admission: ProfileOperationAdmission
        let id: UUID
        let generation: UUID
    }

    private struct Entry {
        let generation: Generation
        let kind: Kind
        var pendingID: UUID?
        var requiredPendingID: UUID?
        var holders = 1
        var revoked = false
        var localOnly = false
        var backgroundInitialization = false
        var acknowledged = false
        var afterTransition: [@Sendable (Scope) -> Void] = []
        var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]
    }

    static let shared = ProfileOperationAdmission(store: .shared)
    static let didReleaseOperation = Notification.Name("ProfileOperationAdmissionDidReleaseOperation")
    @TaskLocal static var current: Scope?
    @TaskLocal private static var currentWalletOperation: WalletOperationScope?

    private let lock = NSLock()
    private let store: ProfileRemovalStore
    private var generation = UUID()
    private var entries: [UUID: Entry] = [:]
    private var exclusive: UUID?
    private var localFailureID: UUID?
    private var drainWaiters: [(UUID, CheckedContinuation<Void, Never>)] = []
    private var walletGeneration = UUID()
    private var walletOperations: [UUID: Bool] = [:]

    init(store: ProfileRemovalStore) {
        self.store = store
    }

    /// Receipt associations belong to the wallet history, not the live profile. Wipe drains their database writes.
    func withReceiptAttribution(_ operation: (@escaping @Sendable () -> Bool) async throws -> Void) async throws {
        try await withWalletOperation(operation)
    }

    func withWalletRestore<T>(_ operation: () async throws -> T) async throws -> T {
        try await withWalletOperation { isCurrent in
            let result = try await operation()
            try Task.checkCancellation()
            guard isCurrent() else { throw ProfileRemovalStore.StoreError.changed }
            return result
        }
    }

    private func withWalletOperation<T>(_ operation: (@escaping @Sendable () -> Bool) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let receipt = try captureWalletOperation()
        defer {
            _ = lock.withLock { walletOperations.removeValue(forKey: receipt.id) }
            resumeDrains()
        }
        return try await withTaskCancellationHandler {
            try await Self.$currentWalletOperation.withValue(receipt) {
                try Task.checkCancellation()
                return try await operation { (try? self.validateWalletOperation(receipt)) != nil }
            }
        } onCancel: {
            self.lock.withLock {
                if self.walletOperations[receipt.id] != nil {
                    self.walletOperations[receipt.id] = false
                }
            }
        }
    }

    func checkReceiptAttribution() throws {
        try Task.checkCancellation()
        guard let receipt = Self.currentWalletOperation, receipt.admission === self else { throw ProfileRemovalStore.StoreError.changed }
        try validateWalletOperation(receipt)
    }

    private func captureWalletOperation() throws -> WalletOperationScope {
        let expected = lock.withLock { walletGeneration }
        guard try store.pending()?.scope != .walletWipe else { throw ProfileRemovalStore.StoreError.pending }
        return try lock.withLock {
            guard localFailureID == nil, walletGeneration == expected,
                  exclusive.flatMap({ entries[$0]?.kind }) != .walletWipe else { throw ProfileRemovalStore.StoreError.changed }
            let receipt = WalletOperationScope(admission: self, id: UUID(), generation: expected)
            walletOperations[receipt.id] = true
            return receipt
        }
    }

    private func validateWalletOperation(_ receipt: WalletOperationScope) throws {
        guard try store.pending()?.scope != .walletWipe else { throw ProfileRemovalStore.StoreError.pending }
        try lock.withLock {
            guard receipt.admission === self, walletOperations[receipt.id] == true, receipt.generation == walletGeneration,
                  localFailureID == nil, exclusive.flatMap({ entries[$0]?.kind }) != .walletWipe
            else { throw ProfileRemovalStore.StoreError.changed }
        }
    }

    func snapshot() throws -> Generation {
        let live = lock.withLock { generation }
        let stored = try store.requireNoPending()
        return try lock.withLock {
            guard localFailureID == nil, exclusive == nil, !entries.values.contains(where: \.revoked),
                  live == generation else { throw ProfileRemovalStore.StoreError.changed }
            return Generation(live: live, stored: stored)
        }
    }

    func validate(_ expected: Generation) throws {
        try store.validate(generation: expected.stored)
        try lock.withLock {
            guard localFailureID == nil, exclusive == nil, !entries.values.contains(where: \.revoked),
                  generation == expected.live else { throw ProfileRemovalStore.StoreError.changed }
        }
    }

    /// Capture before launching detached or queued work. Release only when its actual local/native tail has returned.
    func capture(access: Access = .authenticated) throws -> Scope {
        if let current = Self.current, current.admission === self {
            try validate(current, access: access)
            return try lock.withLock {
                guard var entry = entries[current.id], !entry.revoked else { throw ProfileRemovalStore.StoreError.changed }
                entry.holders += 1
                entries[current.id] = entry
                return current
            }
        }
        let expected = try snapshot()
        return try lock.withLock {
            guard localFailureID == nil, exclusive == nil, generation == expected.live else { throw ProfileRemovalStore.StoreError.changed }
            let scope = Scope(admission: self, id: UUID())
            entries[scope.id] = Entry(generation: expected, kind: .ordinary, pendingID: nil)
            return scope
        }
    }

    func validate(_ scope: Scope, access: Access = .authenticated) throws {
        guard scope.admission === self else { throw ProfileRemovalStore.StoreError.changed }
        let entry = try lock.withLock {
            guard let entry = entries[scope.id], !entry.revoked,
                  localFailureID == nil || (entry.kind != .ordinary && entry.kind != .sessionTransition),
                  entry.kind == .ordinary ? exclusive == nil && entry.generation.live == generation : exclusive == scope.id,
                  access != .authenticated || (!entry.localOnly && entry.kind != .localRecovery)
            else { throw ProfileRemovalStore.StoreError.changed }
            return entry
        }
        if entry.kind == .ordinary || entry.kind == .sessionTransition {
            try store.validate(generation: entry.generation.stored)
            if entry.kind == .sessionTransition, access != .control {
                try lock.withLock {
                    guard !entries.keys.contains(where: { $0 != scope.id }) else { throw ProfileRemovalStore.StoreError.changed }
                }
            }
        } else {
            let pending = try store.pending()
            if let required = entry.requiredPendingID {
                guard pending?.id == required, pending?.scope == .walletWipe else { throw ProfileRemovalStore.StoreError.changed }
            }
            if access != .control {
                guard let pending, pending.id == entry.pendingID else { throw ProfileRemovalStore.StoreError.pending }
            }
            if let pending {
                guard entry.kind == .walletWipe || pending.id == entry.pendingID,
                      entry.kind == .walletWipe || pending.scope == .profile else { throw ProfileRemovalStore.StoreError.changed }
            }
        }
        // File access is outside the admission mutex. A reservation may have changed while it ran.
        try lock.withLock {
            guard let current = entries[scope.id], !current.revoked,
                  localFailureID == nil || (current.kind != .ordinary && current.kind != .sessionTransition),
                  current.kind == .ordinary ? exclusive == nil && current.generation.live == generation : exclusive == scope.id
            else { throw ProfileRemovalStore.StoreError.changed }
        }
    }

    func checkCurrent(access: Access = .authenticated) throws {
        try Task.checkCancellation()
        guard let scope = Self.current else { throw ProfileRemovalStore.StoreError.changed }
        try validate(scope, access: access)
    }

    func withSynchronousOperation<T>(access: Access = .authenticated, _ operation: () throws -> T) throws -> T {
        let scope = try capture(access: access)
        defer { release(scope) }
        return try Self.$current.withValue(scope) {
            try checkCurrent(access: access)
            let result = try operation()
            try validate(scope, access: access)
            return result
        }
    }

    func withOperation<T>(access: Access = .authenticated, _ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let ownsScope = Self.current?.admission !== self
        let scope = try capture(access: access)
        defer { release(scope) }
        return try await withScope(scope, access: access, revokeOnCancellation: ownsScope, operation)
    }

    /// Explicit handoff preserves admission across Task.detached and ServiceQueue, which do not inherit task locals.
    func withScope<T>(_ scope: Scope, access: Access = .authenticated, revokeOnCancellation: Bool = true,
                      _ operation: () async throws -> T) async throws -> T
    {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try validate(scope, access: access)
                let result = try await Self.$current.withValue(scope) { try await operation() }
                if !isAcknowledged(scope) {
                    try Task.checkCancellation()
                }
                try validate(scope, access: access)
                return result
            } catch ProfileRemovalStore.StoreError.changed where Task.isCancelled && !isAcknowledged(scope) {
                // Original cancellation can revoke admission between the task check and a storage read.
                throw CancellationError()
            }
        } onCancel: {
            if revokeOnCancellation {
                self.revokeForCancellation(scope)
            }
        }
    }

    /// Cancellation requests stop queued/waiting work, but the lease remains held until the worker actually returns.
    func withDetached<T>(access: Access = .authenticated, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let ownsScope = Self.current?.admission !== self
        let scope = try capture(access: access)
        let worker = Task.detached {
            try await self.withScope(scope, access: access, revokeOnCancellation: false, operation)
        }
        let handlerID = UUID()
        let cancelled = lock.withLock {
            guard entries[scope.id]?.revoked == false else { return true }
            entries[scope.id]?.cancellationHandlers[handlerID] = { worker.cancel() }
            return false
        }
        if cancelled {
            worker.cancel()
        }
        defer {
            _ = lock.withLock { entries[scope.id]?.cancellationHandlers.removeValue(forKey: handlerID) }
            release(scope)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            try validate(scope, access: access)
            return result
        } onCancel: {
            worker.cancel()
            if ownsScope {
                self.revoke(scope)
            }
        }
    }

    /// Identity replacement owns its full native and local tail. It never creates a removal obligation.
    func reserveSessionTransition(expected: Generation? = nil, backgroundInitialization: Bool = false) throws -> Scope {
        if let current = Self.current, current.admission === self {
            let isTransition = lock.withLock { entries[current.id]?.kind == .sessionTransition }
            guard isTransition else { throw ProfileRemovalStore.StoreError.changed }
            try validate(current)
            if let expected {
                try validateOperationGeneration(expected)
            }
            return try capture()
        }
        // An explicit replacement may retire startup recovery, but never another interactive transition.
        let live = lock.withLock { generation }
        let stored = try store.requireNoPending()
        let expected = expected ?? Generation(live: live, stored: stored)
        try store.validate(generation: expected.stored)
        let scope = try lock.withLock {
            let mayReplaceStartup = !backgroundInitialization && exclusive.flatMap { entries[$0]?.backgroundInitialization } == true
            guard localFailureID == nil, exclusive == nil || mayReplaceStartup,
                  generation == expected.live else { throw ProfileRemovalStore.StoreError.changed }
            for key in entries.keys {
                entries[key]?.revoked = true
            }
            let scope = Scope(admission: self, id: UUID())
            entries[scope.id] = Entry(
                generation: expected,
                kind: .sessionTransition,
                pendingID: nil,
                backgroundInitialization: backgroundInitialization
            )
            exclusive = scope.id
            return scope
        }
        cancelRevokedOperations()
        resumeDrains()
        return scope
    }

    func withSessionTransition<T>(expected: Generation? = nil, _ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let ownsScope = Self.current?.admission !== self
        let scope = try reserveSessionTransition(expected: expected)
        defer { release(scope) }
        do {
            return try await withScope(scope, access: .control, revokeOnCancellation: ownsScope) {
                try await drain(before: scope)
                try validate(scope)
                return try await operation()
            }
        } catch {
            if ownsScope {
                revoke(scope)
            }
            throw error
        }
    }

    /// Linearizes completed identity creation with original cancellation. Wipe revocation remains unconditional.
    func acknowledgeSessionTransition(_ scope: Scope) throws {
        try validate(scope)
        try lock.withLock {
            try Task.checkCancellation()
            guard scope.admission === self, exclusive == scope.id, var entry = entries[scope.id],
                  entry.kind == .sessionTransition, !entry.revoked, localFailureID == nil,
                  !entries.keys.contains(where: { $0 != scope.id }) else { throw ProfileRemovalStore.StoreError.changed }
            entry.acknowledged = true
            entries[scope.id] = entry
        }
    }

    func validateAcknowledgedCompletion() throws {
        guard let scope = Self.current, isAcknowledged(scope) else { throw ProfileRemovalStore.StoreError.changed }
        try validate(scope)
    }

    /// Mandatory Swift state finishes under the retained original owner while a successor drains it.
    /// The outer scope still rejects stale UI completion; this grants no further native or remote work.
    func validateAcknowledgedLocalCompletion() throws {
        guard let scope = Self.current, isAcknowledged(scope) else { throw ProfileRemovalStore.StoreError.changed }
        try validateLocalCompletion(scope)
    }

    func validateCommittedOrCurrentLocalCompletion() throws {
        guard let scope = Self.current else { throw ProfileRemovalStore.StoreError.changed }
        if isAcknowledged(scope) {
            try validateAcknowledgedLocalCompletion()
        } else {
            try checkCurrent()
        }
    }

    private func isAcknowledged(_ scope: Scope) -> Bool {
        lock.withLock { scope.admission === self && entries[scope.id]?.acknowledged == true }
    }

    private func revokeForCancellation(_ scope: Scope) {
        guard scope.admission === self else { return }
        lock.withLock {
            guard entries[scope.id]?.acknowledged != true else { return }
            entries[scope.id]?.revoked = true
        }
        cancelRevokedOperations()
        resumeDrains()
    }

    /// Only a retained original transition can complete its Swift credential writes after cancellation.
    /// This does not authorize SDK authentication or any remote operation.
    func retainLocalCompletion() throws -> Scope {
        guard let scope = Self.current, scope.admission === self else { throw ProfileRemovalStore.StoreError.changed }
        try validate(scope)
        return try lock.withLock {
            guard entries[scope.id]?.kind == .sessionTransition else { throw ProfileRemovalStore.StoreError.changed }
            entries[scope.id]?.holders += 1
            return scope
        }
    }

    func validateLocalCompletion(_ scope: Scope) throws {
        try lock.withLock {
            guard scope.admission === self, let entry = entries[scope.id], entry.kind == .sessionTransition else {
                throw ProfileRemovalStore.StoreError.changed
            }
        }
    }

    /// A cancelled ordinary operation may restore its own local preference before releasing its drain.
    /// This grants no SDK work and cannot cross a reserved identity transition or recovery obligation.
    func validateCancelledPreference(_ scope: Scope) throws {
        let stored = try lock.withLock {
            guard scope.admission === self, let entry = entries[scope.id], entry.kind == .ordinary,
                  exclusive == nil, localFailureID == nil, entry.generation.live == generation
            else {
                throw ProfileRemovalStore.StoreError.changed
            }
            return entry.generation.stored
        }
        try store.validate(generation: stored)
        try lock.withLock {
            guard entries[scope.id] != nil, exclusive == nil, localFailureID == nil,
                  entries[scope.id]?.generation.live == generation else { throw ProfileRemovalStore.StoreError.changed }
        }
    }

    func owns(_ scope: Scope) -> Bool {
        Self.current?.admission === self && Self.current?.id == scope.id
    }

    var hasUnpersistedLocalFailure: Bool {
        lock.withLock { localFailureID != nil }
    }

    /// Only complete backup capture may retry with a fresh owner after transient admission contention.
    /// A durable or unreadable recovery obligation remains closed until explicit local completion.
    func isTransientBackupCaptureFailure(_ error: Error) -> Bool {
        var underlying = error
        for _ in 0 ..< 8 {
            guard let wrapped = underlying as? AppError, let original = wrapped.underlyingError else { break }
            underlying = original
        }
        guard let admissionError = underlying as? ProfileRemovalStore.StoreError, case .changed = admissionError,
              !hasUnpersistedLocalFailure, (try? store.requireNoPending()) != nil else { return false }
        return true
    }

    func recordLocalCompletionFailure(_ scope: Scope, id: UUID) throws {
        try validateLocalCompletion(scope)
        lock.withLock { localFailureID = id }
        try persistLocalFailure()
    }

    /// Retrying this local record write never retries the failed remote operation.
    func persistLocalFailure(recoverMalformed: Bool = false) throws {
        guard let id = lock.withLock({ localFailureID }) else { return }
        if recoverMalformed {
            try store.recoverMalformedRecord(id: id)
        }
        if try store.pending() == nil {
            try store.begin(id: id)
        }
        guard try store.pending() != nil else { throw ProfileRemovalStore.StoreError.unavailable }
        lock.withLock {
            if localFailureID == id {
                localFailureID = nil
            }
        }
    }

    /// Optional work starts under the committed owner, never by recapturing whichever identity is current later.
    /// The callback owns the supplied scope and must release it after its actual tail returns.
    func scheduleAfterTransition(_ operation: @escaping @Sendable (Scope) -> Void) throws {
        if let current = Self.current, current.admission === self {
            try validate(current)
            let deferred = try lock.withLock {
                guard var entry = entries[current.id], !entry.revoked else { throw ProfileRemovalStore.StoreError.changed }
                if entry.kind == .sessionTransition {
                    entry.afterTransition.append(operation)
                    entries[current.id] = entry
                    return true
                }
                return false
            }
            if deferred {
                return
            }
        }
        let scope = try capture()
        Self.$current.withValue(nil) { operation(scope) }
    }

    /// Registration/activation may share a transition. Stable backup snapshots must still reject it.
    func operationGeneration() throws -> Generation {
        if let current = Self.current, current.admission === self,
           let entry = lock.withLock({ entries[current.id] }), entry.kind == .sessionTransition
        {
            try validate(current)
            return entry.generation
        }
        return try snapshot()
    }

    func validateOperationGeneration(_ expected: Generation) throws {
        guard try operationGeneration() == expected else { throw ProfileRemovalStore.StoreError.changed }
    }

    /// Transfers the still-retained startup owner to a distinct local recovery reservation without reopening admission.
    func handoffToLocalRecovery(from scope: Scope, id: UUID) throws -> Scope {
        try validate(scope)
        let next = try lock.withLock {
            guard exclusive == scope.id, let previous = entries[scope.id], previous.kind == .sessionTransition,
                  !previous.revoked, !previous.acknowledged, localFailureID == nil else { throw ProfileRemovalStore.StoreError.changed }
            entries[scope.id]?.revoked = true
            generation = UUID()
            localFailureID = id
            let next = Scope(admission: self, id: UUID())
            entries[next.id] = Entry(generation: Generation(live: generation, stored: previous.generation.stored),
                                     kind: .localRecovery, pendingID: id, localOnly: true)
            exclusive = next.id
            return next
        }
        cancelRevokedOperations()
        resumeDrains()
        return next
    }

    /// Closes admission synchronously. Drain before acquiring an SDK or publication lock.
    func reserve(kind: Kind, id: UUID, expected: Generation? = nil, requiredPendingID: UUID? = nil) throws -> Scope {
        precondition(kind != .ordinary && kind != .sessionTransition)
        if let current = Self.current, current.admission === self {
            throw ProfileRemovalStore.StoreError.changed
        }
        let pending = try store.pending()
        if let requiredPendingID {
            guard kind == .walletWipe, pending?.id == requiredPendingID, pending?.scope == .walletWipe else {
                throw ProfileRemovalStore.StoreError.changed
            }
        }
        if let expected {
            try validate(expected)
        }
        if kind == .removal {
            guard expected != nil, pending == nil else { throw ProfileRemovalStore.StoreError.pending }
        } else if let pending {
            guard kind == .walletWipe || (pending.id == id && pending.scope == .profile) else {
                throw ProfileRemovalStore.StoreError.changed
            }
        } else if kind == .localRecovery {
            guard expected != nil else { throw ProfileRemovalStore.StoreError.changed }
        }
        let stored = pending == nil ? try store.requireNoPending() : UUID()
        let scope = try lock.withLock {
            guard exclusive.flatMap({ entries[$0]?.kind }) != .walletWipe,
                  kind == .walletWipe || exclusive == nil else { throw ProfileRemovalStore.StoreError.pending }
            if let expected, expected.live != generation {
                throw ProfileRemovalStore.StoreError.changed
            }
            if kind == .walletWipe {
                walletGeneration = UUID()
            }
            for key in entries.keys {
                entries[key]?.revoked = true
            }
            generation = UUID()
            let scope = Scope(admission: self, id: UUID())
            entries[scope.id] = Entry(
                generation: Generation(live: generation, stored: stored), kind: kind,
                pendingID: kind == .walletWipe ? pending?.id ?? localFailureID ?? id : id,
                requiredPendingID: requiredPendingID,
                localOnly: pending != nil || localFailureID != nil
            )
            exclusive = scope.id
            return scope
        }
        cancelRevokedOperations()
        resumeDrains()
        return scope
    }

    func drain(before scope: Scope) async throws {
        try validate(scope, access: .control)
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if entries[scope.id]?.revoked == false, hasOutstandingWork(before: scope.id) {
                    drainWaiters.append((scope.id, continuation))
                    return false
                }
                return true
            }
            if ready {
                continuation.resume()
            }
        }
        try Task.checkCancellation()
        try validate(scope, access: .control)
    }

    func persist(_ scope: Scope) throws {
        try validate(scope, access: .control)
        let entry = try lock.withLock {
            guard let entry = entries[scope.id], entry.kind != .ordinary, entry.kind != .sessionTransition,
                  !hasOutstandingWork(before: scope.id) else { throw ProfileRemovalStore.StoreError.changed }
            return entry
        }
        let pending = try store.pending()
        let failureID = lock.withLock { localFailureID }
        let id = entry.kind == .walletWipe ? (pending?.id ?? failureID ?? entry.pendingID) : entry.pendingID
        guard let id else { throw ProfileRemovalStore.StoreError.changed }
        lock.withLock {
            entries[scope.id]?.pendingID = id
            if pending != nil || localFailureID != nil {
                entries[scope.id]?.localOnly = true
            }
        }
        if let required = entry.requiredPendingID {
            try store.begin(id: id, scope: .walletWipe, requiredExistingID: required)
        } else if pending == nil {
            // A prior acknowledged completion may remove its record while the wipe drains that owner.
            // Only the new explicit wipe can start from this post-drain clean generation.
            let expected = entry.kind == .walletWipe ? try store.requireNoPending() : entry.generation.stored
            try store.begin(id: id, scope: entry.kind == .walletWipe ? .walletWipe : .profile, expectedGeneration: expected)
        } else {
            try store.begin(id: id, scope: entry.kind == .walletWipe ? .walletWipe : .profile)
        }
        try validate(scope, access: .control)
        lock.withLock {
            if localFailureID == id {
                localFailureID = nil
            }
        }
    }

    func permitsRemoteCleanup(_ scope: Scope) throws -> Bool {
        try validate(scope, access: .local)
        return try lock.withLock {
            guard let entry = entries[scope.id], entry.kind == .removal || entry.kind == .localRecovery || entry.kind == .walletWipe else {
                throw ProfileRemovalStore.StoreError.changed
            }
            return !entry.localOnly && entry.kind != .localRecovery
        }
    }

    func requireLocalOnly(_ scope: Scope) throws {
        try validate(scope, access: .local)
        try lock.withLock {
            guard let entry = entries[scope.id], entry.kind != .ordinary, entry.kind != .sessionTransition else {
                throw ProfileRemovalStore.StoreError.changed
            }
            entries[scope.id]?.localOnly = true
        }
    }

    @discardableResult
    func complete(_ scope: Scope) throws -> Generation {
        try requireLocalOnly(scope)
        let entry = lock.withLock { entries[scope.id] }
        guard let entry, let id = entry.pendingID else { throw ProfileRemovalStore.StoreError.changed }
        try store.complete(id: id, scope: entry.kind == .walletWipe ? .walletWipe : .profile)
        lock.withLock { localFailureID = nil }
        return try Generation(live: entry.generation.live, stored: store.requireNoPending())
    }

    var isWalletWiping: Bool {
        lock.withLock { exclusive.flatMap { entries[$0]?.kind } == .walletWipe }
    }

    func isWalletWipe(_ scope: Scope) -> Bool {
        guard scope.admission === self else { return false }
        return lock.withLock { exclusive == scope.id && entries[scope.id]?.kind == .walletWipe && entries[scope.id]?.revoked == false }
    }

    func onRevocation(of scope: Scope, id: UUID, cancel: @escaping @Sendable () -> Void) {
        let revoked = lock.withLock {
            guard scope.admission === self, entries[scope.id]?.revoked == false else { return true }
            entries[scope.id]?.cancellationHandlers[id] = cancel
            return false
        }
        if revoked {
            cancel()
        }
    }

    func removeCancellationHandler(from scope: Scope, id: UUID) {
        _ = lock.withLock { entries[scope.id]?.cancellationHandlers.removeValue(forKey: id) }
    }

    func revoke(_ scope: Scope) {
        guard scope.admission === self else { return }
        lock.withLock { entries[scope.id]?.revoked = true }
        cancelRevokedOperations()
        resumeDrains()
    }

    func release(_ scope: Scope) {
        guard scope.admission === self else { return }
        var scheduled: [(@Sendable (Scope) -> Void, Scope)] = []
        var released = false
        lock.withLock {
            guard var entry = entries[scope.id] else { return }
            entry.holders -= 1
            if entry.holders == 0 {
                released = true
                entries.removeValue(forKey: scope.id)
                if exclusive == scope.id {
                    if entry.kind == .sessionTransition {
                        generation = UUID()
                        if !entry.revoked {
                            for operation in entry.afterTransition {
                                let next = Scope(admission: self, id: UUID())
                                entries[next.id] = Entry(generation: Generation(live: generation, stored: entry.generation.stored), kind: .ordinary)
                                scheduled.append((operation, next))
                            }
                        }
                    }
                    exclusive = nil
                }
            } else {
                entries[scope.id] = entry
            }
        }
        resumeDrains()
        Self.$current.withValue(nil) {
            for (operation, scope) in scheduled {
                operation(scope)
            }
        }
        if released {
            NotificationCenter.default.post(name: Self.didReleaseOperation, object: self)
        }
    }

    private func cancelRevokedOperations() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            var handlers: [@Sendable () -> Void] = []
            for id in entries.keys where entries[id]?.revoked == true {
                handlers.append(contentsOf: entries[id]?.cancellationHandlers.values.map { $0 } ?? [])
                entries[id]?.cancellationHandlers.removeAll()
            }
            return handlers
        }
        handlers.forEach { $0() }
    }

    private func resumeDrains() {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            var ready: [CheckedContinuation<Void, Never>] = []
            drainWaiters.removeAll { id, continuation in
                guard entries[id]?.revoked != false || !hasOutstandingWork(before: id) else { return false }
                ready.append(continuation)
                return true
            }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    private func hasOutstandingWork(before id: UUID) -> Bool {
        entries.keys.contains(where: { $0 != id }) || (entries[id]?.kind == .walletWipe && !walletOperations.isEmpty)
    }
}
