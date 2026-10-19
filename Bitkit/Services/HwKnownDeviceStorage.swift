import Combine
import Foundation

/// One wallet identity a paired hardware wallet holds. A Trezor with passphrase protection carries
/// its standard wallet plus one entry per passphrase (hidden) wallet, so `id` (the transport-level
/// device id) is shared by several entries and no longer identifies one on its own.
struct HwKnownDevice: Codable, Equatable, Identifiable {
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
    /// apart from the standard wallet: the xpubs are opaque and the selected mode only lives in
    /// memory, so reconnects would silently fall back to the standard wallet without this. The
    /// passphrase itself is never persisted.
    var passphraseProtected: Bool
    /// The Trezor's own device id, which it regenerates when wiped. Entries of the same transport
    /// reporting a different one belong to a seed the device can no longer sign for.
    var trezorDeviceId: String?
    /// The maker of the device. Entries stored before other vendors existed carry none: they are
    /// Trezor ones, unless their ids sit in the Jade namespace.
    let vendor: HwWalletVendor
    /// The Jade's own device id (its efuse MAC), which outlives a change of Bluetooth identifier.
    var jadeDeviceId: String?
    /// The stored vendor of an entry a newer build wrote for a vendor this one does not know. Such an
    /// entry belongs to no vendor's slice and is written back with its vendor unchanged, so rolling
    /// back never drops a wallet paired on the newer build.
    private(set) var unknownVendor: String?

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
        trezorDeviceId: String? = nil,
        vendor: HwWalletVendor = .trezor,
        jadeDeviceId: String? = nil
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
        self.vendor = vendor
        self.jadeDeviceId = jadeDeviceId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case transportType
        case label
        case model
        case lastConnectedAt
        case xpubs
        case customLabel
        case walletId
        case passphraseProtected
        case trezorDeviceId
        case vendor
        case jadeDeviceId
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
        jadeDeviceId = try container.decodeIfPresent(String.self, forKey: .jadeDeviceId)

        // Decoded as a string, not as the enum: an unknown value would otherwise fail the whole
        // device list, and the next write would then drop every paired wallet.
        let storedVendor = try? container.decodeIfPresent(String.self, forKey: .vendor)
        vendor = storedVendor.flatMap(HwWalletVendor.init(rawValue:)) ?? Self.inferredVendor(id: id, walletId: walletId)
        unknownVendor = storedVendor.flatMap { HwWalletVendor(rawValue: $0) == nil ? $0 : nil }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(transportType, forKey: .transportType)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(lastConnectedAt, forKey: .lastConnectedAt)
        try container.encode(xpubs, forKey: .xpubs)
        try container.encodeIfPresent(customLabel, forKey: .customLabel)
        try container.encodeIfPresent(walletId, forKey: .walletId)
        try container.encode(passphraseProtected, forKey: .passphraseProtected)
        try container.encodeIfPresent(trezorDeviceId, forKey: .trezorDeviceId)
        try container.encode(unknownVendor ?? vendor.rawValue, forKey: .vendor)
        try container.encodeIfPresent(jadeDeviceId, forKey: .jadeDeviceId)
    }

    private static func inferredVendor(id: String, walletId: String?) -> HwWalletVendor {
        let jadeNamespace = "\(HwWalletVendor.blockstream.deviceType):"
        return id.hasPrefix(jadeNamespace) || walletId?.hasPrefix(jadeNamespace) == true ? .blockstream : .trezor
    }
}

extension HwKnownDevice {
    /// Identity of the key material this entry holds: entries sharing it are the same wallet, on
    /// this device or on another transport. An entry read before any xpub was captured has no key
    /// material to compare, so it falls back to its transport id.
    var walletKey: String {
        HwKnownDevice.walletKey(for: xpubs, fallback: id)
    }

    static func walletKey(for xpubs: [String: String], fallback: String) -> String {
        xpubs.isEmpty ? fallback : xpubs.values.sorted().joined(separator: "\u{1f}")
    }

    /// Wallet id of this identity: the stored one, or derived from the xpubs in the vendor's namespace
    /// for entries written before it was persisted. The derivation is unchanged, so those keep the id
    /// they always had.
    var resolvedWalletId: String? {
        if let walletId, !walletId.isEmpty {
            return walletId
        }
        return try? HwWalletId.derive(xpubs: xpubs, vendor: vendor)
    }

    /// Stable key for lists and diffing, since `id` is shared by every identity of one device.
    var entryId: String {
        "\(id)\u{1f}\(walletKey)"
    }

    /// The vendor's own stable device id, when the device reported one.
    var hardwareId: String? {
        switch vendor {
        case .trezor: trezorDeviceId
        case .blockstream: jadeDeviceId
        }
    }

    /// Whether this entry is part of `vendor`'s slice of the store.
    func belongs(to vendor: HwWalletVendor) -> Bool {
        unknownVendor == nil && self.vendor == vendor
    }

    /// This entry as last reached over `path` at `date`, keeping everything else it holds.
    func refreshed(path: String, at date: Date) -> HwKnownDevice {
        var refreshed = HwKnownDevice(
            id: id,
            name: name,
            path: path,
            transportType: transportType,
            label: label,
            model: model,
            lastConnectedAt: date,
            xpubs: xpubs,
            customLabel: customLabel,
            walletId: walletId,
            passphraseProtected: passphraseProtected,
            trezorDeviceId: trezorDeviceId,
            vendor: vendor,
            jadeDeviceId: jadeDeviceId
        )
        refreshed.unknownVendor = unknownVendor
        return refreshed
    }
}

/// A pending-name change to apply together with a device-list write; a nil `name` drops the entry.
struct PendingHwWalletName: Equatable {
    let walletId: String
    let name: String?
}

/// Persists paired hardware wallet entries of every vendor in UserDefaults. Each vendor's manager
/// reads and writes only its own slice; the wallet names and their backup span every vendor.
/// THP credentials remain in Keychain via TrezorCredentialStorage.
enum HwKnownDeviceStorage {
    /// Fires when the set of hardware wallet names changes, so the metadata backup can be marked
    /// stale. Every connect rewrites the device list to refresh `lastConnectedAt`, and reconnect
    /// traffic must not re-upload the whole envelope, so this only fires on a real name change.
    static let namesChangedPublisher = namesChangedSubject.eraseToAnyPublisher()

    // Named before other vendors existed; renaming them would unpair every stored wallet.
    private static let key = "trezor.knownDevices"
    private static let pendingNamesKey = "trezor.pendingWalletNames"
    private static let namesChangedSubject = PassthroughSubject<Void, Never>()

    /// Load the known devices of `vendor`, or of every vendor when nil, most recently connected first.
    /// Entries of a vendor this build does not know are never returned.
    static func loadAll(vendor: HwWalletVendor? = nil) -> [HwKnownDevice] {
        storedDevices()
            .filter { $0.unknownVendor == nil && (vendor == nil || $0.vendor == vendor) }
            .sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    /// Save or update one wallet identity within its vendor's slice. Scoped to the identity rather
    /// than to the transport it was reached over, so a passphrase wallet is stored next to the
    /// device's standard wallet instead of replacing it.
    static func save(_ device: HwKnownDevice) {
        var devices = loadAll(vendor: device.vendor)
        devices.removeAll { $0.id == device.id && $0.walletKey == device.walletKey }
        devices.insert(device, at: 0)
        saveAll(devices, vendor: device.vendor)
    }

    /// Replace `vendor`'s slice with `devices` as-is, keeping every other vendor's entries. Used for
    /// bulk updates (e.g. renaming every entry of a device shared across transports) without
    /// per-device reordering.
    ///
    /// - Parameter vendor: the slice being replaced. Required, so a vendor's manager can never write
    /// away the entries of another vendor.
    /// - Parameter pendingName: a pending-name change to apply in the same call, or nil to leave the
    /// pending names alone. It is written *first*: crashing between the two writes then leaves a name
    /// recorded for a wallet that is still paired, which the next pairing masks away, rather than a
    /// forgotten wallet whose name was recorded nowhere.
    static func saveAll(_ devices: [HwKnownDevice], vendor: HwWalletVendor, pendingName: PendingHwWalletName? = nil) {
        let slice = devices.filter { $0.belongs(to: vendor) }
        assert(slice.count == devices.count, "Only \(vendor) entries belong in the \(vendor) slice")
        let previousNames = backupSnapshot()
        if let pendingName {
            writePendingName(pendingName)
        }
        writeDevices(loadAll().filter { !$0.belongs(to: vendor) } + slice)
        notifyIfNamesChanged(from: previousNames)
    }

    /// Entries tracking one wallet identity.
    static func loadAll(walletId: String) -> [HwKnownDevice] {
        loadAll().filter { $0.resolvedWalletId == walletId }
    }

    /// Forget every identity of one of `vendor`'s devices, whichever wallets it holds.
    static func remove(id: String, vendor: HwWalletVendor) {
        let devices = loadAll()
        let isTarget = { (device: HwKnownDevice) in device.id == id && device.belongs(to: vendor) }
        forget(devices.filter(isTarget), keeping: devices.filter { !isTarget($0) })
    }

    /// Forget a single wallet identity, leaving the device's other wallets paired.
    static func remove(walletId: String) {
        let devices = loadAll()
        forget(
            devices.filter { $0.resolvedWalletId == walletId },
            keeping: devices.filter { $0.resolvedWalletId != walletId }
        )
    }

    /// Remove every remembered hardware wallet, whatever its vendor.
    static func removeAll() {
        let previousNames = backupSnapshot()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: pendingNamesKey)
        notifyIfNamesChanged(from: previousNames)
    }

    /// Whether a device is known, among `vendor`'s entries or among every vendor's when nil.
    static func isKnown(id: String, vendor: HwWalletVendor? = nil) -> Bool {
        loadAll(vendor: vendor).contains { $0.id == id }
    }

    // MARK: - Hardware wallet names

    /// Names of wallets that no device entry carries: restored from a backup before the device was
    /// paired again, or kept when the wallet was removed.
    ///
    /// A wallet the device list already names is masked out rather than pruned, so pairing consumes
    /// a pending name by simply adopting it, with no second write that could be lost on its own.
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
    /// sees. Entries without a wallet id are skipped: only a device stored before any account key
    /// was captured has none, and such an entry is filtered out of the wallet list anyway, so it can
    /// never have been named.
    static func backupSnapshot() -> [String: String] {
        storedPendingNames().merging(pairedNames()) { _, paired in paired }
    }

    /// Merges backed up names into the pending ones, so each is adopted the next time its wallet is
    /// paired. Names already held locally win: they were set on this device after the backup was
    /// written. Never clears: an envelope without names predates the field and must not drop what is
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
    private static func forget(_ forgotten: [HwKnownDevice], keeping remaining: [HwKnownDevice]) {
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

    private static func storedDevices() -> [HwKnownDevice] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HwKnownDevice].self, from: data)) ?? []
    }

    /// Writes `devices` together with the entries of vendors this build does not know, which no
    /// read ever returns and so no caller could pass back.
    private static func writeDevices(_ devices: [HwKnownDevice]) {
        let unknownVendorEntries = storedDevices().filter { $0.unknownVendor != nil }
        let knownVendorEntries = devices.filter { $0.unknownVendor == nil }
        guard let data = try? JSONEncoder().encode(knownVendorEntries + unknownVendorEntries) else { return }
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
