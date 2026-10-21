import BitkitCore

/// The live Trezor session and its stored entries, as the watch-only layer needs them.
///
/// Implemented by `TrezorManager` and injected into `HwWalletManager`, so the watch-only layer can
/// reason about which wallet a session belongs to without either manager referencing the other.
/// Everything here is device-level on purpose: resolving a wallet identity to the transport it is
/// reachable over is the watch-only layer's job, since it owns the wallet grouping.
@MainActor
protocol TrezorSessioning: AnyObject, Sendable {
    /// Stored entries read fresh. A connect that just wrote one lands here before the
    /// `updateDevices(...)` push does, so session operations must not read the pushed snapshot.
    var storedDevices: [HwKnownDevice] { get }
    var connectedDeviceId: String? { get }
    /// Identity the live session opened; nil when no session is open or none could be resolved.
    var connectedWalletId: String? { get }
    var connectedFeatures: TrezorFeatures? { get }
    /// Whether a session is open, being opened or being restored, so another vendor has to wait for
    /// it to be released before it can use the radio.
    var isSessionActive: Bool { get }

    func ensureConnected(deviceId: String) async throws
    /// Opens `deviceId` with an explicit wallet selection, with or without a live session.
    @discardableResult
    func connectWithWalletMode(
        deviceId: String,
        mode: TrezorWalletMode,
        passphrase: String
    ) async throws -> TrezorFeatures
    func disconnectStaleSession(deviceId: String) async
    /// Closes the session, after any connection work already running, so another vendor can take
    /// over. Runs to completion even when the caller is cancelled.
    func releaseSession() async
    /// Starts a silent reconnect of a known device, as on returning to the foreground, unless one is
    /// running. The session reads as active from this call on, and releasing it cancels the reconnect.
    func startAutoReconnect()
    /// Drops the session and any pending reconnect ahead of a wallet wipe.
    func resetForWipe() async
    func isKnownBluetoothDevice(deviceId: String) -> Bool
    func warmUpConnection(deviceId: String)
    /// Forgets every stored entry of `walletId`, keeping transport credentials while another
    /// identity of the same device remains paired.
    ///
    /// - Parameter pendingName: a name to keep for the wallet being forgotten, so re-pairing the
    /// device restores it, or nil to drop any name kept for it. It rides the same store write that
    /// forgets the entries, so the device list is never published while the name is missing.
    func forgetWallet(walletId: String, pendingName: PendingHwWalletName?) async
    func renameWallet(walletId: String, newName: String)
}

extension TrezorManager: TrezorSessioning {
    var storedDevices: [HwKnownDevice] {
        knownDevices
    }

    var connectedDeviceId: String? {
        connectedDevice?.id
    }

    var connectedFeatures: TrezorFeatures? {
        deviceFeatures
    }
}

/// The live Jade session and its stored entries, as the watch-only layer needs them.
///
/// The Jade counterpart of `TrezorSessioning`, injected into `HwWalletManager` so it can route every
/// device call by the vendor stored on a paired entry. A Jade holds one wallet and has no passphrase
/// wallets, so there is no wallet selection here; it compares receive addresses on the device itself
/// and signs a PSBT that the session finalizes.
@MainActor
protocol JadeSessioning: AnyObject, Sendable {
    /// Stored Jade entries read fresh, for the same reason as `TrezorSessioning.storedDevices`.
    var storedDevices: [HwKnownDevice] { get }
    var connectedDeviceId: String? { get }
    /// Identity the live session opened; nil when no session is open or none could be resolved.
    var connectedWalletId: String? { get }
    /// Whether a session is open, being opened, or a background reconnect is pending.
    var isSessionActive: Bool { get }

    /// Reuses a live session of `deviceId`, else reconnects it. A locked session is unlocked, which
    /// waits for the PIN on the device.
    func ensureConnected(deviceId: String) async throws
    /// Shows `expectedAddress` on the device, which compares it itself and throws
    /// `JadeError.AddressMismatch` when it derives another one.
    func verifyAddress(addressType: AddressScriptType, derivationPath: String, expectedAddress: String) async throws
    func masterFingerprint() async throws -> String
    /// Signs on the device, then finalizes the signed PSBT into a broadcastable transaction.
    func signPsbt(_ psbtBase64: String) async throws -> CompletedTransaction
    /// Closes the link together with the core session, so a device call waiting on the link lets go of
    /// core. A no-op while another Jade is connected.
    func disconnectStaleSession(deviceId: String) async
    /// Disconnects, or cancels a pending connect and background reconnect, so another vendor can take
    /// over the radio.
    func releaseSession() async
    func isKnownBluetoothDevice(deviceId: String) -> Bool
    /// Best-effort silent pre-connect before signing. Never unlocks.
    func warmUpConnection(deviceId: String)
    /// Forgets every stored entry of `walletId`, closing the session when it holds that wallet. See
    /// `TrezorSessioning.forgetWallet` for `pendingName`.
    func forgetWallet(walletId: String, pendingName: PendingHwWalletName?) async
    func renameWallet(walletId: String, newName: String)
    /// Starts a silent background reconnect of the most recently used Jade, unless one is running.
    /// Never unlocks.
    func startAutoReconnect()
    func onAppBackgrounded()
    func onAppBecameActive()
    /// Drops the session and any background work ahead of a wallet wipe.
    func resetForWipe() async
}
