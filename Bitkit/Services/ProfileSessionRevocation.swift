import Foundation

final class ProfileSessionRevocation: @unchecked Sendable {
    let validate: @Sendable () async throws -> Void
    let execute: @Sendable () async throws -> Void
    let acknowledged: @Sendable () async -> Bool
    let clearCredentials: @Sendable () async throws -> Void
    let revoke: @Sendable () -> Void
    private let release: @Sendable () -> Void

    init(validate: @escaping @Sendable () async throws -> Void,
         execute: @escaping @Sendable () async throws -> Void,
         acknowledged: @escaping @Sendable () async -> Bool,
         clearCredentials: @escaping @Sendable () async throws -> Void,
         revoke: @escaping @Sendable () -> Void,
         release: @escaping @Sendable () -> Void = {})
    {
        self.validate = validate
        self.execute = execute
        self.acknowledged = acknowledged
        self.clearCredentials = clearCredentials
        self.revoke = revoke
        self.release = release
    }

    deinit {
        revoke()
        release()
    }
}
