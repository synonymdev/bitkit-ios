import Combine
import Foundation

/// One wallet identity a Trezor holds. A device with passphrase protection carries its standard
/// wallet plus one entry per passphrase (hidden) wallet, so `id` — the transport-level device id —
/// is shared by several entries and no longer identifies one on its own.
struct TrezorKnownDevice: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let transportType: String
    var label: String?
    var model: String?
    var lastConnectedAt: Date
    /// Account-level extended public keys keyed by `AddressScriptType.stringValue`.
    /// Persisted so watch-only balances/activity stay available while disconnected.
    var xpubs: [String: String]
    /// User-set name applied while managing the wallet in Bitkit; nil until renamed. Takes priority
    /// over the device's own `label`/`model` when resolving the display name.
    var customLabel: String?
    /// bitkit-core wallet id of this identity. Absent on entries stored before hidden wallets
    /// existed, where `resolvedWalletId` derives it from `xpubs` instead.
    var walletId: String?
    /// Whether this entry is a passphrase (hidden) wallet. Nothing else in the record can tell one
    /// apart from the standard wallet — the xpubs are opaque and the selected mode only lives in
    /// memory, so reconnects would silently fall back to the standard wallet without this. The
    /// passphrase itself is never persisted.
    var passphraseProtected: Bool
    /// The Trezor's own device id, which it regenerates when wiped. Entries of the same transport
    /// reporting a different one belong to a seed the device can no longer sign for.
    var trezorDeviceId: String?

    init(
        id: String,
        name: String,
        path: String,
        transportType: String,
        label: String? = nil,
        model: String? = nil,
        lastConnectedAt: Date,
        xpubs: [String: String] = [:],
        customLabel: String? = nil,
        walletId: String? = nil,
        passphraseProtected: Bool = false,
        trezorDeviceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.transportType = transportType
        self.label = label
        self.model = model
        self.lastConnectedAt = lastConnectedAt
        self.xpubs = xpubs
        self.customLabel = customLabel
        self.walletId = walletId
        self.passphraseProtected = passphraseProtected
        self.trezorDeviceId = trezorDeviceId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        transportType = try container.decode(String.self, forKey: .transportType)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        lastConnectedAt = try container.decode(Date.self, forKey: .lastConnectedAt)
        xpubs = try container.decodeIfPresent([String: String].self, forKey: .xpubs) ?? [:]
        customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
        walletId = try container.decodeIfPresent(String.self, forKey: .walletId)
        passphraseProtected = try container.decodeIfPresent(Bool.self, forKey: .passphraseProtected) ?? false
        trezorDeviceId = try container.decodeIfPresent(String.self, forKey: .trezorDeviceId)
    }
}

extension TrezorKnownDevice {
    /// Identity of the key material this entry holds: entries sharing it are the same wallet, on
    /// this device or on another transport. An entry read before any xpub was captured has no key
    /// material to compare, so it falls back to its transport id.
    var walletKey: String {
        TrezorKnownDevice.walletKey(for: xpubs, fallback: id)
    }

    static func walletKey(for xpubs: [String: String], fallback: String) -> String {
        xpubs.isEmpty ? fallback : xpubs.values.sorted().joined(separator: "\u{1f}")
    }

    /// Wallet id of this identity: the stored one, or derived from the xpubs for entries written
    /// before it was persisted. The derivation is unchanged, so those keep the id they always had.
    var resolvedWalletId: String? {
        if let walletId, !walletId.isEmpty { return walletId }
        return try? HwWalletId.derive(xpubs: xpubs)
    }

    /// Stable key for lists and diffing, since `id` is shared by every identity of one device.
    var entryId: String {
        "\(id)\u{1f}\(walletKey)"
    }
}

/// A pending-name change to apply together with a device-list write; a nil `name` drops the entry.
struct PendingHwWalletName: Equatable {
    let walletId: String
    let name: String?
}

/// Persists known Trezor device metadata in UserDefaults
/// THP credentials remain in Keychain via TrezorCredentialStorage
enum TrezorKnownDeviceStorage {
    /// Fires when the set of hardware wallet names changes, so the metadata backup can be marked
    /// stale. Every connect rewrites the device list to refresh `lastConnectedAt`, and reconnect
    /// traffic must not re-upload the whole envelope, so this only fires on a real name change.
    static let namesChangedPublisher = namesChangedSubject.eraseToAnyPublisher()

    private static let key = "trezor.knownDevices"
    private static let pendingNamesKey = "trezor.pendingWalletNames"
    private static let namesChangedSubject = PassthroughSubject<Void, Never>()

    /// Load all known devices, sorted by most recently connected
    static func loadAll() -> [TrezorKnownDevice] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let devices = (try? JSONDecoder().decode([TrezorKnownDevice].self, from: data)) ?? []
        return devices.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    /// Save or update one wallet identity. Scoped to the identity rather than to the transport it
    /// was reached over, so a passphrase wallet is stored next to the device's standard wallet
    /// instead of replacing it.
    static func save(_ device: TrezorKnownDevice) {
        var devices = loadAll()
        devices.removeAll { $0.id == device.id && $0.walletKey == device.walletKey }
        devices.insert(device, at: 0)
        saveAll(devices)
    }

    /// Persist the full device list as-is. Used for bulk updates (e.g. renaming every entry of a
    /// device shared across transports) without per-device reordering.
    ///
    /// - Parameter pendingName: a pending-name change to apply in the same call, or nil to leave the
    /// pending names alone. It is written *first*: crashing between the two writes then leaves a name
    /// recorded for a wallet that is still paired, which the next pairing masks away, rather than a
    /// forgotten wallet whose name was recorded nowhere.
    static func saveAll(_ devices: [TrezorKnownDevice], pendingName: PendingHwWalletName? = nil) {
        let previousNames = backupSnapshot()
        if let pendingName {
            writePendingName(pendingName)
        }
        writeDevices(devices)
        notifyIfNamesChanged(from: previousNames)
    }

    /// Entries tracking one wallet identity.
    static func loadAll(walletId: String) -> [TrezorKnownDevice] {
        loadAll().filter { $0.resolvedWalletId == walletId }
    }

    /// Forget every identity of a device, whichever wallets it holds.
    static func remove(id: String) {
        let devices = loadAll()
        forget(devices.filter { $0.id == id }, keeping: devices.filter { $0.id != id })
    }

    /// Forget a single wallet identity, leaving the device's other wallets paired.
    static func remove(walletId: String) {
        let devices = loadAll()
        forget(
            devices.filter { $0.resolvedWalletId == walletId },
            keeping: devices.filter { $0.resolvedWalletId != walletId }
        )
    }

    /// Remove all remembered Trezor devices.
    static func removeAll() {
        let previousNames = backupSnapshot()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: pendingNamesKey)
        notifyIfNamesChanged(from: previousNames)
    }

    /// Check if a device is known
    static func isKnown(id: String) -> Bool {
        loadAll().contains { $0.id == id }
    }

    // MARK: - Hardware wallet names

    /// Names of wallets that no device entry carries: restored from a backup before the device was
    /// paired again, or kept when the wallet was removed.
    ///
    /// A wallet the device list already names is masked out rather than pruned, so pairing consumes
    /// a pending name by simply adopting it — no second write that could be lost on its own.
    static func loadPendingNames() -> [String: String] {
        let paired = pairedNames()
        return storedPendingNames().filter { paired[$0.key] == nil }
    }

    /// Stores the name of a wallet with no device entry, or drops it when `name` is nil or blank.
    static func setPendingName(walletId: String, name: String?) {
        let previousNames = backupSnapshot()
        writePendingName(PendingHwWalletName(walletId: walletId, name: name))
        notifyIfNamesChanged(from: previousNames)
    }

    /// Every hardware wallet name this wallet knows, keyed by wallet id: the pending ones overlaid
    /// with the name of each paired wallet. A paired name wins because it is what the user currently
    /// sees. Entries without a wallet id are skipped — only a device stored before any account key
    /// was captured has none, and such an entry is filtered out of the wallet list anyway, so it can
    /// never have been named.
    static func backupSnapshot() -> [String: String] {
        storedPendingNames().merging(pairedNames()) { _, paired in paired }
    }

    /// Merges backed up names into the pending ones, so each is adopted the next time its wallet is
    /// paired. Names already held locally win: they were set on this device after the backup was
    /// written. Never clears — an envelope without names predates the field and must not drop what is
    /// stored.
    static func restoreNames(_ names: [String: String]) {
        guard !names.isEmpty else { return }
        let previousNames = backupSnapshot()
        writePendingNames(names.merging(storedPendingNames()) { _, local in local })
        notifyIfNamesChanged(from: previousNames)
    }

    // MARK: - Storage

    /// Drop `forgotten` from the device list and with it any name kept for the wallets it held: a
    /// removal that wanted to keep a name writes it back through `saveAll(_:pendingName:)` instead.
    private static func forget(_ forgotten: [TrezorKnownDevice], keeping remaining: [TrezorKnownDevice]) {
        let previousNames = backupSnapshot()
        let remainingWalletIds = Set(remaining.compactMap(\.resolvedWalletId))
        var pending = storedPendingNames()
        for walletId in forgotten.compactMap(\.resolvedWalletId) where !remainingWalletIds.contains(walletId) {
            pending[walletId] = nil
        }
        writePendingNames(pending)
        writeDevices(remaining)
        notifyIfNamesChanged(from: previousNames)
    }

    private static func writeDevices(_ devices: [TrezorKnownDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func storedPendingNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: pendingNamesKey) as? [String: String] ?? [:]
    }

    private static func writePendingName(_ update: PendingHwWalletName) {
        guard !update.walletId.isEmpty else { return }
        var pending = storedPendingNames()
        pending[update.walletId] = update.name.flatMap { $0.isEmpty ? nil : $0 }
        writePendingNames(pending)
    }

    private static func writePendingNames(_ names: [String: String]) {
        if names.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingNamesKey)
        } else {
            UserDefaults.standard.set(names, forKey: pendingNamesKey)
        }
    }

    private static func pairedNames() -> [String: String] {
        var names: [String: String] = [:]
        for device in loadAll() {
            guard let walletId = device.resolvedWalletId, !walletId.isEmpty else { continue }
            guard let label = device.customLabel, !label.isEmpty else { continue }
            names[walletId] = label
        }
        return names
    }

    private static func notifyIfNamesChanged(from previousNames: [String: String]) {
        guard backupSnapshot() != previousNames else { return }
        namesChangedSubject.send()
    }
}
