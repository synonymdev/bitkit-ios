import Combine
import Foundation
import VssRustClientFfi

@MainActor
final class ConnectionRecoveryService: ObservableObject {
    enum AdmissionError: Error {
        case busy
    }

    struct Owner: Codable, Equatable {
        let walletIndex: Int
        let network: String
        let binding: String
    }

    struct Record: Codable, Equatable {
        let version: Int
        let owner: Owner
        let revision: UUID
        var electrum: ElectrumServer?
        var rgs: String?
    }

    struct Editor {
        let owner: Owner
        let generation: UUID
        let revision: UUID?
        let electrum: ElectrumServer
        let rgs: String
    }

    private final class Access {
        let service: ConnectionRecoveryService
        let id: UUID
        let generation: UUID
        var owner: Owner?

        init(service: ConnectionRecoveryService, id: UUID, generation: UUID) {
            self.service = service
            self.id = id
            self.generation = generation
        }
    }

    @TaskLocal private static var access: Access?

    static let shared = ConnectionRecoveryService(
        owner: {
            guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else {
                throw CustomServiceError.mnemonicNotFound
            }
            let passphrase = try Keychain.loadString(key: .bip39Passphrase(index: 0))
            let namespace = try vssDeriveStoreId(
                prefix: Env.vssStoreIdPrefix, mnemonic: mnemonic,
                passphrase: passphrase?.isEmpty == true ? nil : passphrase
            )
            return Owner(walletIndex: 0, network: Env.networkName,
                         binding: PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet.binding(storeId: namespace))
        },
        load: { try Keychain.load(key: .connectionRecovery) },
        store: { try Keychain.upsert(key: .connectionRecovery, data: $0) },
        clear: { try Keychain.delete(key: .connectionRecovery) }
    )

    @Published private(set) var isBusy = false
    var lifecycleID: UUID {
        generation
    }

    private var generation = UUID()
    private var readyGeneration: UUID?
    private var wipeID: UUID?
    private var isWiping: Bool {
        wipeID != nil
    }

    private var activeID: UUID?
    private var cancelActive: (() -> Void)?
    private var drainActive: (() async -> Void)?
    private let owner: () throws -> Owner
    private let load: () throws -> Data?
    private let store: (Data) throws -> Void
    private let clear: () throws -> Void
    private let defaults: UserDefaults

    init(
        owner: @escaping () throws -> Owner,
        load: @escaping () throws -> Data?,
        store: @escaping (Data) throws -> Void,
        clear: @escaping () throws -> Void,
        defaults: UserDefaults = .standard
    ) {
        self.owner = owner
        self.load = load
        self.store = store
        self.clear = clear
        self.defaults = defaults
    }

    func perform<T>(cancelsWithCaller: Bool = true, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        if let access = Self.access, access.service === self {
            try validate(access)
            return try await body()
        }
        try Task.checkCancellation()
        guard !isWiping, activeID == nil else { throw AdmissionError.busy }
        let access = Access(service: self, id: UUID(), generation: generation)
        activeID = access.id
        readyGeneration = nil
        isBusy = true
        let task = Task { @MainActor in
            try await Self.$access.withValue(access) {
                try self.validate(access)
                let value = try await body()
                try self.validate(access)
                return value
            }
        }
        cancelActive = { task.cancel() }
        drainActive = { _ = await task.result }
        defer {
            if activeID == access.id {
                activeID = nil
                cancelActive = nil
                drainActive = nil
                isBusy = false
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            if cancelsWithCaller {
                task.cancel()
            }
        }
    }

    func beginWipe() async throws -> UUID {
        guard wipeID == nil else { throw AdmissionError.busy }
        let id = UUID()
        wipeID = id
        readyGeneration = nil
        generation = UUID()
        cancelActive?()
        await drainActive?()
        return id
    }

    func endWipe(_ id: UUID) {
        guard wipeID == id else { return }
        wipeID = nil
    }

    func isCurrentLifecycle(_ id: UUID) -> Bool {
        !isWiping && generation == id
    }

    func requiresRestrictedStartup(hasPendingRestore: Bool) -> Bool {
        if hasPendingRestore {
            return true
        }
        do { return try load() != nil } catch { return true }
    }

    func canFinishInitialization(lifecycle: UUID, isRunning: Bool, hasPendingRestore: Bool, didFail: Bool) -> Bool {
        isCurrentLifecycle(lifecycle) && readyGeneration == lifecycle && !isBusy && isRunning && !hasPendingRestore && !didFail
    }

    func editor() throws -> Editor {
        guard !isWiping, !isBusy else { throw failure("Connection recovery is already in progress") }
        let currentOwner = try owner()
        let record = try read(for: currentOwner)
        return Editor(owner: currentOwner, generation: generation, revision: record?.revision,
                      electrum: record?.electrum ?? ElectrumConfigService(defaults: defaults).getCurrentServer(),
                      rgs: record?.rgs ?? RgsConfigService(defaults: defaults).getCurrentServerUrl())
    }

    func isCurrent(_ editor: Editor) -> Bool {
        !isWiping && editor.generation == generation && (try? owner()) == editor.owner
    }

    func save(
        editor: Editor,
        electrum: ElectrumServer? = nil,
        rgs: String? = nil,
        validateEndpoint: @escaping () async throws -> Void = {}
    ) async throws {
        try await perform {
            try self.requireCurrent(editor)
            try await validateEndpoint()
            try self.requireCurrent(editor)
            var record = try self.read(for: editor.owner)
            guard record?.revision == editor.revision else { throw self.failure("Connection settings changed; reopen the editor") }
            record = Record(version: 1, owner: editor.owner, revision: UUID(),
                            electrum: electrum ?? record?.electrum, rgs: rgs ?? record?.rgs)
            guard let record, record.electrum != nil || record.rgs != nil else { return }
            let data = try JSONEncoder().encode(record)
            try self.store(data)
            guard try self.load() == data else { throw self.failure("Connection settings could not be saved") }
            try self.apply(record)
        }
    }

    func replay() throws -> UUID? {
        let access = try currentAccess()
        guard let record = try read(for: boundOwner(access)) else { return nil }
        try apply(record)
        return record.revision
    }

    func restoreRequired(
        gate: WalletBackupRestoreGate,
        restore: @escaping (Data?) async throws -> Bool
    ) async throws -> Bool {
        try await perform {
            try await gate.performRestore { retained in
                _ = try self.replay()
                let restored = try await restore(retained)
                _ = try self.replay()
                return restored
            }
        }
    }

    func mergeRestoredSettings(_ settings: [String: Any]) throws -> [String: Any] {
        let access = try currentAccess()
        guard let record = try read(for: boundOwner(access)) else { return settings }
        var merged = settings
        if let electrum = record.electrum {
            merged["electrumServer"] = electrum.fullUrl
        }
        if let rgs = record.rgs {
            merged["rgsServerUrl"] = rgs
        }
        return merged
    }

    func complete(revision: UUID?, hasPendingRestore: Bool, isRunning: Bool, onReady: () -> Void = {}) throws {
        let access = try currentAccess()
        guard !hasPendingRestore, isRunning else { return }
        if let revision {
            guard let record = try read(for: boundOwner(access)), record.revision == revision else { return }
            try apply(record)
            try clear()
            guard try load() == nil else { throw failure("Connection recovery could not be finalized") }
        } else {
            guard try read(for: boundOwner(access)) == nil else { return }
        }
        readyGeneration = generation
        onReady()
    }

    func checkCurrentOperation() throws {
        guard let access = Self.access, access.service === self else { throw failure("Connection recovery requires an active wallet operation") }
        try validate(access)
    }

    func canReportOperationFailure() -> Bool {
        guard let access = Self.access, access.service === self else { return false }
        return !isWiping && activeID == access.id && generation == access.generation
    }

    private func currentAccess() throws -> Access {
        guard let access = Self.access, access.service === self else { throw failure("Connection recovery requires an active wallet operation") }
        try validate(access)
        _ = try boundOwner(access)
        return access
    }

    private func boundOwner(_ access: Access) throws -> Owner {
        if let original = access.owner {
            return original
        }
        let original = try owner()
        access.owner = original
        return original
    }

    private func validate(_ access: Access) throws {
        try Task.checkCancellation()
        guard !isWiping, activeID == access.id, generation == access.generation else {
            throw failure("Wallet changed during connection recovery")
        }
        if let original = access.owner, try owner() != original {
            throw failure("Wallet changed during connection recovery")
        }
    }

    private func requireCurrent(_ editor: Editor) throws {
        _ = try currentAccess()
        guard isCurrent(editor) else { throw failure("Wallet changed; reopen connection settings") }
    }

    private func read(for owner: Owner) throws -> Record? {
        guard let data = try load() else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1, record.owner.walletIndex >= 0,
              !record.owner.network.isEmpty, !record.owner.binding.isEmpty,
              record.electrum != nil || record.rgs != nil else { throw failure("Saved connection recovery is unavailable") }
        if let server = record.electrum, server.host.isEmpty || !(1 ... 65535).contains(server.port) {
            throw failure("Saved Electrum settings are invalid")
        }
        guard record.owner == owner else { throw failure("Saved connection recovery belongs to another wallet") }
        return record
    }

    private func apply(_ record: Record) throws {
        _ = try currentAccess()
        if let electrum = record.electrum {
            let data = try JSONEncoder().encode(electrum)
            defaults.set(data, forKey: "electrumServer")
            guard defaults.data(forKey: "electrumServer") == data else { throw failure("Electrum settings could not be saved") }
        }
        if let rgs = record.rgs {
            defaults.set(rgs, forKey: "rapidGossipSyncUrl")
            guard defaults.string(forKey: "rapidGossipSyncUrl") == rgs else { throw failure("RGS settings could not be saved") }
        }
        guard defaults.synchronize() else { throw failure("Connection settings could not be persisted") }
    }

    private func failure(_ message: String) -> Error {
        AppError(message: message, debugMessage: nil)
    }
}
