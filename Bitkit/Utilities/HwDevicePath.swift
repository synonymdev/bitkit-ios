import Foundation

/// Transport paths of hardware wallet devices. A Bluetooth device is addressed as `ble:<UUID>`, where
/// the UUID is the identifier CoreBluetooth gives the peripheral on this phone.
enum HwDevicePath {
    static let blePrefix = "ble:"

    static func ble(_ identifier: UUID) -> String {
        blePrefix + identifier.uuidString
    }

    static func isBle(_ path: String) -> Bool {
        path.hasPrefix(blePrefix)
    }

    static func bleIdentifier(_ path: String) -> UUID? {
        guard isBle(path) else { return nil }
        return UUID(uuidString: String(path.dropFirst(blePrefix.count)))
    }
}
