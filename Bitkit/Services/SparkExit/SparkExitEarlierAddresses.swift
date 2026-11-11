import BitkitCore
import Combine
import Foundation

/// A funding address an earlier exit left coins at, or may still receive them at, with the path that spends it. Kept
/// apart from the record, so a later exit can start and replace the record while the address stays reachable.
struct SparkExitEarlierAddress: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// Fee funding left at the funding address for good: change too small to send, or a refused sweep's.
        case keptChange
        /// The funding address of a cancelled exit that was forgotten: a late payment can still land there.
        case cancelledFunding
    }

    let address: String
    let path: String
    let kind: Kind
    /// What the address holds, when known.
    var sats: UInt64?
    let date: Date

    var id: String {
        address
    }

    /// About four weeks: how long a cancelled exit's address is still read for a late payment.
    static let watchSeconds: TimeInterval = 28 * 24 * 3600

    /// Read in the foreground for what it holds: kept change always, so change spent by hand shows as spent, and a
    /// cancelled exit's address younger than `watchSeconds`, for a late payment.
    func isWatched(now: Date) -> Bool {
        kind == .keptChange || now.timeIntervalSince(date) < Self.watchSeconds
    }

    /// The leftover an ended exit kept at its funding address.
    static func keptChange(_ record: SparkExitRecord, network: BitkitCore.Network, at date: Date) -> SparkExitEarlierAddress? {
        guard record.isLeftoverKept, let address = record.funding.first?.address else { return nil }
        return SparkExitEarlierAddress(
            address: address,
            path: SparkExitFundingKey.path(index: record.fundingIndex, network: network),
            kind: .keptChange,
            sats: record.leftover.reduce(0) { $0 + $1.valueSats },
            date: date
        )
    }

    /// The funding address of a cancelled exit being forgotten.
    static func cancelledFunding(_ record: SparkExitRecord, network: BitkitCore.Network, at date: Date) -> SparkExitEarlierAddress? {
        guard let address = record.funding.first?.address else { return nil }
        return SparkExitEarlierAddress(
            address: address,
            path: SparkExitFundingKey.path(index: record.fundingIndex, network: network),
            kind: .cancelledFunding,
            sats: nil,
            date: date
        )
    }

    /// The entries with what each watched address holds now; one that can't be read keeps what it showed.
    static func refreshed(
        _ entries: [SparkExitEarlierAddress],
        now: Date,
        utxos: (String) async throws -> [EsploraUtxo]
    ) async -> [SparkExitEarlierAddress] {
        await updating(entries, balances: balances(entries, now: now, utxos: utxos))
    }

    /// What each watched address that could be read holds now, by address.
    static func balances(
        _ entries: [SparkExitEarlierAddress],
        now: Date,
        utxos: (String) async throws -> [EsploraUtxo]
    ) async -> [String: UInt64] {
        var balances: [String: UInt64] = [:]
        for entry in entries where entry.isWatched(now: now) {
            guard let held = try? await utxos(entry.address) else { continue }
            balances[entry.address] = held.reduce(0) { $0 + $1.value }
        }
        return balances
    }

    /// The entries with the `balances` read; the others keep what they showed.
    static func updating(_ entries: [SparkExitEarlierAddress], balances: [String: UInt64]) -> [SparkExitEarlierAddress] {
        entries.map { entry in
            guard let sats = balances[entry.address] else { return entry }
            var updated = entry
            updated.sats = sats > 0 ? sats : nil
            return updated
        }
    }
}

/// The earlier exits' addresses of a wallet, across exits. A wipe deletes it with the record.
struct SparkExitEarlierAddressStore {
    /// Sends on every write of any wallet's list, so the metadata backup that carries them runs again.
    static let savedPublisher = savedSubject.eraseToAnyPublisher()
    private static let savedSubject = PassthroughSubject<Void, Never>()

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(walletIndex: Int) {
        url = Env.sparkExitEarlierAddresses(walletIndex: walletIndex)
    }

    func load() throws -> [SparkExitEarlierAddress] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([SparkExitEarlierAddress].self, from: Data(contentsOf: url))
    }

    /// Adds `entry` unless its address is listed already. Kept change at a cancelled exit's address, which a later exit
    /// reused, replaces that entry, so it is read for good.
    @discardableResult
    func add(_ entry: SparkExitEarlierAddress) throws -> [SparkExitEarlierAddress] {
        let stored = (try? load()) ?? []
        if let index = stored.firstIndex(where: { $0.address == entry.address }) {
            guard entry.kind == .keptChange, stored[index].kind != .keptChange else { return stored }
            var entries = stored
            entries[index] = entry
            try save(entries)
            return entries
        }
        let entries = stored + [entry]
        try save(entries)
        return entries
    }

    func save(_ entries: [SparkExitEarlierAddress]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Self.savedSubject.send()
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The earlier exit addresses in the metadata backup.
enum SparkExitEarlierAddressBackup {
    /// The entries of `store`, keyed `walletKey`; nil with none, or when the list can't be read, which then never
    /// blocks the rest of the metadata.
    static func backup(_ store: SparkExitEarlierAddressStore, walletKey: String) -> [String: [SparkExitEarlierAddressBackupV1]]? {
        guard let entries = try? store.load(), !entries.isEmpty else { return nil }
        return [walletKey: entries.map(\.backup)]
    }

    /// Lists each backed-up address of `network` in its wallet's store, next to the entries already there.
    static func restore(
        _ backedUp: [String: [SparkExitEarlierAddressBackupV1]]?,
        network: String,
        store: (Int) -> SparkExitEarlierAddressStore
    ) {
        for (key, entries) in backedUp ?? [:] {
            let prefix = "\(network)/wallet"
            guard key.hasPrefix(prefix), let walletIndex = Int(key.dropFirst(prefix.count)) else { continue }
            let walletStore = store(walletIndex)
            for entry in entries.compactMap(SparkExitEarlierAddress.init(backup:)) {
                do {
                    try walletStore.add(entry)
                } catch {
                    Logger.warn("Failed to restore the earlier Spark exit address: \(error)", context: "SparkExitEarlierAddressBackup")
                }
            }
        }
    }
}

extension SparkExitEarlierAddress {
    var backup: SparkExitEarlierAddressBackupV1 {
        SparkExitEarlierAddressBackupV1(
            address: address,
            path: path,
            kind: kind.rawValue,
            atMillis: Int64((date.timeIntervalSince1970 * 1000).rounded())
        )
    }

    /// The backed-up entry, with what it holds read again later; nil for a kind this app does not know.
    init?(backup: SparkExitEarlierAddressBackupV1) {
        guard let kind = Kind(rawValue: backup.kind) else { return nil }
        self.init(
            address: backup.address,
            path: backup.path,
            kind: kind,
            sats: nil,
            date: Date(timeIntervalSince1970: Double(backup.atMillis) / 1000)
        )
    }
}
