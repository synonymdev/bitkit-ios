import Foundation

/// A local cleanup obligation, independent of credentials and preferences that cleanup removes.
/// It never establishes that a remote mutation succeeded or authorizes replaying one.
final class ProfileRemovalStore: @unchecked Sendable {
    enum Scope: String, Codable {
        case profile
        case walletWipe
    }

    struct Pending: Codable, Equatable {
        let version: Int
        let id: UUID
        let scope: Scope
    }

    enum StoreError: Error {
        case unavailable
        case pending
        case changed
    }

    static let didChange = Notification.Name("ProfileRemovalStoreDidChange")

    static let shared = ProfileRemovalStore(
        url: Env.appStorageUrl.appendingPathComponent(Env.networkName)
            .appendingPathComponent("wallet0/profile-removal-v1.json")
    )

    private let lock = NSLock()
    private let url: URL
    private let write: (Data, URL) throws -> Void
    private let remove: (URL) throws -> Void
    private var generation = UUID()
    private var observed: Pending?

    init(
        url: URL,
        write: @escaping (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        },
        remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.url = url
        self.write = write
        self.remove = remove
    }

    func pending() throws -> Pending? {
        try lock.withLock { try readLocked() }
    }

    @discardableResult
    func requireNoPending() throws -> UUID {
        try lock.withLock {
            guard try readLocked() == nil else { throw StoreError.pending }
            return generation
        }
    }

    func validate(generation expected: UUID) throws {
        try lock.withLock {
            guard try readLocked() == nil, generation == expected else { throw StoreError.changed }
        }
    }

    func begin(id: UUID, scope: Scope = .profile, expectedGeneration: UUID? = nil, requiredExistingID: UUID? = nil) throws {
        try lock.withLock {
            let current = try readLocked()
            if let requiredExistingID {
                guard current?.id == requiredExistingID, current?.scope == scope else { throw StoreError.changed }
            }
            if let expectedGeneration {
                guard current == nil, generation == expectedGeneration else { throw StoreError.changed }
            }
            guard current == nil || current?.id == id else { throw StoreError.changed }
            // A partially completed wallet wipe must not be downgraded to profile-only recovery.
            guard current?.scope != .walletWipe || scope == .walletWipe else { throw StoreError.changed }
            let next = Pending(version: 1, id: id, scope: scope)
            if current == next {
                return
            }
            #if DEBUG
                if self === Self.shared {
                    try ProfileRemovalTestFault.check("marker:persist")
                }
            #endif
            try write(JSONEncoder().encode(next), url)
            observed = next
            generation = UUID()
        }
        if self === Self.shared {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Call only after every required credential and local-state write has been acknowledged.
    func complete(id: UUID, scope: Scope = .profile) throws {
        try lock.withLock {
            guard let current = try readLocked(), current.id == id, current.scope == scope else {
                throw StoreError.changed
            }
            #if DEBUG
                if self === Self.shared {
                    try ProfileRemovalTestFault.check("marker:complete")
                }
            #endif
            try remove(url)
            observed = nil
            generation = UUID()
        }
        if self === Self.shared {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// An explicit local recovery can repair only this version's identifiable damaged record.
    /// Unknown formats and unreadable storage remain untouched.
    func recoverMalformedRecord(id: UUID = UUID()) throws {
        try lock.withLock {
            do { _ = try readLocked(); return } catch {}
            let bytes = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  object["version"] as? Int == 1,
                  let rawScope = object["scope"] as? String, let scope = Scope(rawValue: rawScope)
            else { throw StoreError.unavailable }
            guard try Data(contentsOf: url) == bytes else { throw StoreError.changed }
            let next = Pending(version: 1, id: id, scope: scope)
            try write(JSONEncoder().encode(next), url)
            guard try readLocked() == next else { throw StoreError.unavailable }
        }
        if self === Self.shared {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private func readLocked() throws -> Pending? {
        var value: Pending?
        do {
            let data = try Data(contentsOf: url)
            value = try JSONDecoder().decode(Pending.self, from: data)
            guard value?.version == 1 else { throw StoreError.unavailable }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            value = nil
        } catch {
            throw StoreError.unavailable
        }
        if value != observed {
            generation = UUID()
            observed = value
        }
        return value
    }
}
