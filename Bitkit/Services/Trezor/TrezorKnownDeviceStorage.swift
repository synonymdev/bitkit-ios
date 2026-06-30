import Foundation

/// Represents a previously connected Trezor device
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

    init(
        id: String,
        name: String,
        path: String,
        transportType: String,
        label: String? = nil,
        model: String? = nil,
        lastConnectedAt: Date,
        xpubs: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.transportType = transportType
        self.label = label
        self.model = model
        self.lastConnectedAt = lastConnectedAt
        self.xpubs = xpubs
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

    /// Save or update a known device
    static func save(_ device: TrezorKnownDevice) {
        var devices = loadAll()
        devices.removeAll { $0.id == device.id }
        devices.insert(device, at: 0)
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Remove a known device by ID
    static func remove(id: String) {
        var devices = loadAll()
        devices.removeAll { $0.id == id }
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
