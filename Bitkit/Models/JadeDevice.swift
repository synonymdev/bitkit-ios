import BitkitCore
import Foundation

/// The live Jade session: the paired entry it belongs to and the state the device last reported.
struct ConnectedJadeDevice: Equatable {
    let id: String
    let path: String
    var versionInfo: JadeVersionInfo
    /// Wallet the session holds; nil when its accounts could not be resolved to one.
    let walletId: String?

    var isLocked: Bool {
        versionInfo.jadeState == .locked
    }

    var model: String {
        JadeDeviceIdentity.model(boardType: versionInfo.boardType)
    }

    func matches(_ deviceId: String) -> Bool {
        id == deviceId || path == deviceId
    }
}

/// How a Jade is recognised across connections. Its Bluetooth identifier changes after a reboot or a
/// pairing reset, while its efuse MAC does not, so the MAC is the identity.
enum JadeDeviceIdentity {
    /// A Jade advertises as "Jade" followed by the last six hex digits of its efuse MAC.
    static let nameSuffixLength = 6
    static let defaultName = "Jade"

    /// Stable entry id from the efuse MAC, so a Jade reached under a new Bluetooth identifier refreshes
    /// its entry instead of adding one. Nil when the device reported no MAC.
    static func deviceId(efuseMac: String?) -> String? {
        guard let efuseMac, !efuseMac.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "\(HwWalletVendor.blockstream.deviceType):bluetooth:\(efuseMac)"
    }

    /// Jade Plus reports a v2 board; every other board is the original Jade.
    static func model(boardType: String?) -> String {
        boardType?.uppercased().contains("V2") == true ? "Jade Plus" : defaultName
    }

    /// Whether `name` is what the Jade with `jadeDeviceId` advertises as. A MAC too short to carry the
    /// suffix proves nothing, so it never matches.
    static func advertises(_ name: String?, jadeDeviceId: String?) -> Bool {
        guard let name, let jadeDeviceId, jadeDeviceId.count >= nameSuffixLength else { return false }
        let suffix = jadeDeviceId.suffix(nameSuffixLength)
        guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return name.lowercased().hasSuffix(suffix.lowercased())
    }
}

extension JadeState {
    /// Whether the device can serve requests that need its keys.
    var isUnlocked: Bool {
        self == .ready || self == .temp
    }
}

extension HwKnownDevice {
    func matches(deviceId: String) -> Bool {
        id == deviceId || path == deviceId
    }

    func advertisesAs(_ name: String?) -> Bool {
        JadeDeviceIdentity.advertises(name, jadeDeviceId: jadeDeviceId)
    }

    /// Whether a scanned Jade is this paired one, even when it came back under a new Bluetooth
    /// identifier after a reboot.
    func isSameJade(as device: JadeDeviceInfo) -> Bool {
        switch device.transport {
        case .bluetooth:
            path == device.path || advertisesAs(device.name)
        case .serial:
            // A plugged-in Jade cannot be told from a paired one before connecting.
            transportType == "usb"
        }
    }
}
