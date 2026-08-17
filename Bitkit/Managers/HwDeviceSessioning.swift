import BitkitCore

/// The live Trezor session and its stored entries, as the watch-only layer needs them.
///
/// Implemented by `TrezorManager` and injected into `HwWalletManager`, so the watch-only layer can
/// reason about which wallet a session belongs to without either manager referencing the other.
/// Everything here is device-level on purpose: resolving a wallet identity to the transport it is
/// reachable over is the watch-only layer's job, since it owns the wallet grouping.
@MainActor
protocol HwDeviceSessioning: AnyObject, Sendable {
    /// Stored entries read fresh. A connect that just wrote one lands here before the
    /// `updateDevices(...)` push does, so session operations must not read the pushed snapshot.
    var storedDevices: [TrezorKnownDevice] { get }
    var connectedDeviceId: String? { get }
    /// Identity the live session opened; nil when no session is open or none could be resolved.
    var connectedWalletId: String? { get }
    var connectedFeatures: TrezorFeatures? { get }

    func ensureConnected(deviceId: String) async throws
    /// Opens `deviceId` with an explicit wallet selection, with or without a live session.
    @discardableResult
    func connectWithWalletMode(
        deviceId: String,
        mode: TrezorWalletMode,
        passphrase: String
    ) async throws -> TrezorFeatures
    func disconnectStaleSession(deviceId: String) async
    func isKnownBluetoothDevice(deviceId: String) -> Bool
    func warmUpConnection(deviceId: String)
    /// Forgets every stored entry of `walletId`, keeping transport credentials while another
    /// identity of the same device remains paired.
    func forgetWallet(walletId: String) async
}

extension TrezorManager: HwDeviceSessioning {
    var storedDevices: [TrezorKnownDevice] {
        knownDevices
    }

    var connectedDeviceId: String? {
        connectedDevice?.id
    }

    var connectedFeatures: TrezorFeatures? {
        deviceFeatures
    }
}
