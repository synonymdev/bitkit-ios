import BitkitCore
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
        var refreshed = entries
        for i in refreshed.indices where refreshed[i].isWatched(now: now) {
            guard let held = try? await utxos(refreshed[i].address) else { continue }
            let sats = held.reduce(0) { $0 + $1.value }
            refreshed[i].sats = sats > 0 ? sats : nil
        }
        return refreshed
    }
}

/// The earlier exits' addresses of a wallet, across exits. A wipe deletes it with the record.
struct SparkExitEarlierAddressStore {
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

    /// Adds `entry` unless its address is listed already.
    @discardableResult
    func add(_ entry: SparkExitEarlierAddress) throws -> [SparkExitEarlierAddress] {
        let stored = (try? load()) ?? []
        guard !stored.contains(where: { $0.address == entry.address }) else { return stored }
        let entries = stored + [entry]
        try save(entries)
        return entries
    }

    func save(_ entries: [SparkExitEarlierAddress]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
