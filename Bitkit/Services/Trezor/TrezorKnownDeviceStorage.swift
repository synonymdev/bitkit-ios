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

/// Persists known Trezor device metadata in UserDefaults
/// THP credentials remain in Keychain via TrezorCredentialStorage
enum TrezorKnownDeviceStorage {
    private static let key = "trezor.knownDevices"

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
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Persist the full device list as-is. Used for bulk updates (e.g. renaming every entry of a
    /// device shared across transports) without per-device reordering.
    static func saveAll(_ devices: [TrezorKnownDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Entries tracking one wallet identity.
    static func loadAll(walletId: String) -> [TrezorKnownDevice] {
        loadAll().filter { $0.resolvedWalletId == walletId }
    }

    /// Forget every identity of a device, whichever wallets it holds.
    static func remove(id: String) {
        var devices = loadAll()
        devices.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Forget a single wallet identity, leaving the device's other wallets paired.
    static func remove(walletId: String) {
        var devices = loadAll()
        devices.removeAll { $0.resolvedWalletId == walletId }
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Remove all remembered Trezor devices.
    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Check if a device is known
    static func isKnown(id: String) -> Bool {
        loadAll().contains { $0.id == id }
    }
}
