import Foundation
import LDKNode

/// App-side mirror of the offline receive request states reported by the node binding.
enum OfflineReceiveNodeStatus: Equatable {
    case preparing
    case awaitingActivation
    case awaitingWitnesses
    case ready(bolt11: String)
    case expired
    case settled(fulfilled: Bool)
    case failed(reason: String)
}

enum OfflineReceiveNodeError: Error, Equatable {
    case disabled
    case unavailable
    case ineligible
    case requestNotFound
    case requestConflict
}

/// Minimal surface of the node's offline receive API so the provider can be tested without the native framework.
protocol OfflineReceiveNodeClient {
    func nodeId() async throws -> String
    func canReceive(amountMsat: UInt64) async throws -> Bool
    func prepare(requestId: String, amountMsat: UInt64, description: String) async throws -> OfflineReceiveNodeStatus
    func status(requestId: String) async throws -> OfflineReceiveNodeStatus
    func cancel(requestId: String) async throws
}

struct OfflineReceiveInvoiceSummary: Equatable {
    let amountMsat: UInt64?
    let payeeNodeId: String
}

struct OfflineReceiveRequestRecord: Codable, Equatable {
    let requestId: String
    let amountSats: UInt64
    let description: String
}

/// Durable memory of which node request identity belongs to which receive intent,
/// so a restart resumes the same request instead of preparing a second one.
protocol OfflineReceiveRequestStore {
    func load() -> [OfflineReceiveRequestRecord]
    func save(_ records: [OfflineReceiveRequestRecord])
}

extension OfflineReceiveRequestStore {
    static var capacity: Int { 16 }

    func record(amountSats: UInt64, description: String) -> OfflineReceiveRequestRecord? {
        load().first { $0.amountSats == amountSats && $0.description == description }
    }

    func remember(_ record: OfflineReceiveRequestRecord) {
        var records = load().filter { !($0.amountSats == record.amountSats && $0.description == record.description) }
        records.append(record)
        save(Array(records.suffix(Self.capacity)))
    }

    func forget(requestId: String) {
        save(load().filter { $0.requestId != requestId })
    }
}

final class UserDefaultsOfflineReceiveRequestStore: OfflineReceiveRequestStore {
    static let key = "offlineReceivePendingRequests"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [OfflineReceiveRequestRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([OfflineReceiveRequestRecord].self, from: data)) ?? []
    }

    func save(_ records: [OfflineReceiveRequestRecord]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

final class InMemoryOfflineReceiveRequestStore: OfflineReceiveRequestStore {
    private(set) var records: [OfflineReceiveRequestRecord] = []

    init(records: [OfflineReceiveRequestRecord] = []) {
        self.records = records
    }

    func load() -> [OfflineReceiveRequestRecord] { records }
    func save(_ records: [OfflineReceiveRequestRecord]) { self.records = records }
}

/// Offline receive provider backed by the LDK Node offline receive API.
/// Only a request the node reports as ready produces an invoice, and that invoice is checked
/// for the exact amount and our own node as payee before it is handed to the receive flow.
@MainActor
final class LdkOfflineReceiveProvider: OfflineReceiveProviding {
    typealias Inspect = @MainActor (String) throws -> OfflineReceiveInvoiceSummary
    typealias Sleep = (TimeInterval) async throws -> Void

    static let defaultTimeout: TimeInterval = 60
    static let defaultPollInterval: TimeInterval = 0.5

    private let client: any OfflineReceiveNodeClient
    private let store: any OfflineReceiveRequestStore
    private let inspect: Inspect
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let now: @MainActor () -> Date
    private let sleep: Sleep

    init(
        client: any OfflineReceiveNodeClient,
        store: any OfflineReceiveRequestStore = UserDefaultsOfflineReceiveRequestStore(),
        inspect: @escaping Inspect = LdkOfflineReceiveProvider.inspectBolt11,
        timeout: TimeInterval = LdkOfflineReceiveProvider.defaultTimeout,
        pollInterval: TimeInterval = LdkOfflineReceiveProvider.defaultPollInterval,
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.client = client
        self.store = store
        self.inspect = inspect
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
    }

    static func inspectBolt11(_ bolt11: String) throws -> OfflineReceiveInvoiceSummary {
        let invoice = try Bolt11Invoice.fromStr(invoiceStr: bolt11)
        return OfflineReceiveInvoiceSummary(amountMsat: invoice.amountMilliSatoshis(), payeeNodeId: invoice.recoverPayeePubKey())
    }

    func canReceive(amountSats: UInt64) async throws -> Bool {
        guard let amountMsat = Self.amountMsat(amountSats) else { return false }
        do {
            return try await client.canReceive(amountMsat: amountMsat)
        } catch OfflineReceiveNodeError.disabled, OfflineReceiveNodeError.unavailable, OfflineReceiveNodeError.ineligible {
            return false
        }
    }

    func prepareInvoice(requestId: String, amountSats: UInt64, description: String) async throws -> PreparedOfflineInvoice {
        guard let amountMsat = Self.amountMsat(amountSats) else { throw OfflineReceiveError.insufficientLiquidity }
        let deadline = now().addingTimeInterval(timeout)
        let (record, initialStatus) = try await begin(requestId: requestId, amountSats: amountSats, amountMsat: amountMsat, description: description)
        var status = initialStatus

        while true {
            try Task.checkCancellation()
            switch status {
            case let .ready(bolt11):
                try await validate(bolt11: bolt11, amountMsat: amountMsat, record: record)
                return PreparedOfflineInvoice(bolt11: bolt11)
            case .expired, .settled, .failed:
                store.forget(requestId: record.requestId)
                throw OfflineReceiveError.unavailable
            case .preparing, .awaitingActivation, .awaitingWitnesses:
                guard now() < deadline else { throw OfflineReceiveError.unavailable }
                try await sleep(pollInterval)
                try Task.checkCancellation()
                status = try await poll(record: record)
            }
        }
    }

    /// Releases the node request behind an intent. The receive UI does not expose this yet.
    func cancel(requestId: String) async throws {
        do {
            try await client.cancel(requestId: requestId)
        } catch OfflineReceiveNodeError.requestNotFound {}
        store.forget(requestId: requestId)
    }

    private func begin(
        requestId: String,
        amountSats: UInt64,
        amountMsat: UInt64,
        description: String
    ) async throws -> (OfflineReceiveRequestRecord, OfflineReceiveNodeStatus) {
        if let stored = store.record(amountSats: amountSats, description: description) {
            do {
                return try await (stored, client.status(requestId: stored.requestId))
            } catch OfflineReceiveNodeError.requestNotFound {
                store.forget(requestId: stored.requestId)
            } catch let error as OfflineReceiveNodeError {
                throw Self.map(error)
            }
        }
        let record = OfflineReceiveRequestRecord(requestId: requestId, amountSats: amountSats, description: description)
        store.remember(record)
        do {
            return try await (record, client.prepare(requestId: requestId, amountMsat: amountMsat, description: description))
        } catch let error as OfflineReceiveNodeError {
            store.forget(requestId: requestId)
            throw Self.map(error)
        }
    }

    private func poll(record: OfflineReceiveRequestRecord) async throws -> OfflineReceiveNodeStatus {
        do {
            return try await client.status(requestId: record.requestId)
        } catch let error as OfflineReceiveNodeError {
            store.forget(requestId: record.requestId)
            throw Self.map(error)
        }
    }

    private func validate(bolt11: String, amountMsat: UInt64, record: OfflineReceiveRequestRecord) async throws {
        let summary = try? inspect(bolt11)
        let nodeId = try await client.nodeId()
        guard let summary, summary.amountMsat == amountMsat, summary.payeeNodeId.lowercased() == nodeId.lowercased() else {
            store.forget(requestId: record.requestId)
            throw OfflineReceiveError.invalidInvoice
        }
    }

    private static func amountMsat(_ amountSats: UInt64) -> UInt64? {
        let (amountMsat, overflow) = amountSats.multipliedReportingOverflow(by: 1000)
        guard amountSats > 0, !overflow else { return nil }
        return amountMsat
    }

    private static func map(_ error: OfflineReceiveNodeError) -> OfflineReceiveError {
        switch error {
        case .disabled, .unavailable, .ineligible, .requestNotFound, .requestConflict: .unavailable
        }
    }
}

/// Keeps the real provider behind the developer toggle so a production build never advertises offline receive.
@MainActor
struct DeveloperGatedOfflineReceiveProvider: OfflineReceiveProviding {
    let isEnabled: @MainActor () -> Bool
    let provider: any OfflineReceiveProviding

    func canReceive(amountSats: UInt64) async throws -> Bool {
        guard isEnabled() else { return false }
        return try await provider.canReceive(amountSats: amountSats)
    }

    func prepareInvoice(requestId: String, amountSats: UInt64, description: String) async throws -> PreparedOfflineInvoice {
        guard isEnabled() else { throw OfflineReceiveError.unavailable }
        return try await provider.prepareInvoice(requestId: requestId, amountSats: amountSats, description: description)
    }
}

enum OfflineReceiveProviderSelection {
    /// The real provider exists only in builds compiled against the local binding and stays gated behind the developer toggle.
    @MainActor
    static func provider(lightningService: LightningService = .shared) -> any OfflineReceiveProviding {
        #if OFFLINE_RECEIVE_LOCAL_LDK
            return DeveloperGatedOfflineReceiveProvider(
                isEnabled: { OfflineReceiveSettings.isEnabled() },
                provider: LdkOfflineReceiveProvider(client: LdkNodeOfflineReceiveClient(lightningService: lightningService))
            )
        #else
            _ = lightningService
            return UnavailableOfflineReceiveProvider()
        #endif
    }
}
