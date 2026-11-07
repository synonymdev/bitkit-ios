@testable import Bitkit
import Foundation

final class ProfileRevocationTestDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var didAcknowledge = false
    private var didRevoke = false
    private let execute: @MainActor () async throws -> Void
    private let clear: @MainActor () async throws -> Void
    private let validate: @MainActor () async throws -> Void

    init(execute: @escaping @MainActor () async throws -> Void = {},
         clear: @escaping @MainActor () async throws -> Void = {},
         validate: @escaping @MainActor () async throws -> Void = {})
    {
        self.execute = execute
        self.clear = clear
        self.validate = validate
    }

    var revoked: Bool {
        lock.withLock { didRevoke }
    }

    func acknowledge() {
        lock.withLock { didAcknowledge = true }
    }

    private func requireCurrent() throws {
        guard !revoked else { throw ProfileRemovalStore.StoreError.changed }
    }

    func handle() -> ProfileSessionRevocation {
        ProfileSessionRevocation(validate: { [self] in
            try requireCurrent()
            try await validate()
        }, execute: { [self] in
            try requireCurrent()
            try await execute()
            acknowledge()
        }, acknowledged: { [self] in lock.withLock { didAcknowledge } }, clearCredentials: { [self] in
            guard lock.withLock({ didAcknowledge }) else { throw ProfileRemovalStore.StoreError.changed }
            try await clear()
        }, revoke: { [self] in lock.withLock { didRevoke = true } })
    }
}
