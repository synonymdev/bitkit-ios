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

    /// Check if a device is known
    static func isKnown(id: String) -> Bool {
        loadAll().contains { $0.id == id }
    }
}
