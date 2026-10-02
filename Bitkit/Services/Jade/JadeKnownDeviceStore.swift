import Foundation

/// The paired Jade entries and the pending wallet names, as `JadeManager` reads and writes them.
protocol JadeKnownDeviceStoring {
    /// Paired Jade entries, most recently connected first.
    func loadAll() -> [HwKnownDevice]
    /// Replaces the Jade entries, leaving every other vendor's alone. See `HwKnownDeviceStorage.saveAll`
    /// for `pendingName`.
    func saveAll(_ devices: [HwKnownDevice], pendingName: PendingHwWalletName?)
    func loadPendingNames() -> [String: String]
    func setPendingName(walletId: String, name: String?)
}

/// The Jade slice of `HwKnownDeviceStorage`.
struct JadeKnownDeviceStore: JadeKnownDeviceStoring {
    func loadAll() -> [HwKnownDevice] {
        HwKnownDeviceStorage.loadAll(vendor: .blockstream)
    }

    func saveAll(_ devices: [HwKnownDevice], pendingName: PendingHwWalletName?) {
        HwKnownDeviceStorage.saveAll(devices, vendor: .blockstream, pendingName: pendingName)
    }

    func loadPendingNames() -> [String: String] {
        HwKnownDeviceStorage.loadPendingNames()
    }

    func setPendingName(walletId: String, name: String?) {
        HwKnownDeviceStorage.setPendingName(walletId: walletId, name: name)
    }
}
