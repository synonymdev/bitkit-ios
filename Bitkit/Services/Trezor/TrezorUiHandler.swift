import BitkitCore
import Combine
import Foundation

/// Which wallet to open when the device asks for a passphrase.
///
/// - `standard`: no passphrase — the default wallet.
/// - `passphraseHost`: a hidden wallet, passphrase typed on the phone.
/// - `passphraseDevice`: a hidden wallet, passphrase typed on the Trezor.
enum TrezorWalletMode {
    case standard
    case passphraseHost
    case passphraseDevice
}

/// Implementation of TrezorUiCallback protocol for PIN and passphrase handling.
///
/// PIN entry still blocks the Rust calling thread until the user responds via the
/// UI (the semaphore pattern shared with TrezorTransport.getPairingCode()).
///
/// Passphrase handling follows the bitkit-android model: the user selects a wallet
/// mode up front (Standard / hidden-on-phone / hidden-on-device) and that selection
/// is bound to the THP session at connect time via `currentSelection()`. The device
/// callback `onPassphraseRequest` is answered silently from the stored mode — this is
/// what non-THP (legacy) devices use when they re-request the passphrase mid-operation.
final class TrezorUiHandler: TrezorUiCallback {
    static let shared = TrezorUiHandler()

    // MARK: - PIN Handling

    /// Publisher to notify UI when PIN entry is needed
    let needsPinPublisher = PassthroughSubject<Void, Never>()

    private var submittedPin: String = ""
    private let pinLock = NSLock()
    private let pinSemaphore = DispatchSemaphore(value: 0)

    /// Timeout for PIN entry (2 minutes)
    private static let timeoutSeconds: TimeInterval = 120

    // MARK: - Wallet Mode / Passphrase Selection

    private let modeLock = NSLock()
    private var walletMode: TrezorWalletMode = .standard

    /// Host passphrase captured when `.passphraseHost` is selected. Mirrors the value
    /// bound to the THP session so legacy (non-THP) devices — which re-request the
    /// passphrase mid-operation via `onPassphraseRequest` — can be answered from the
    /// value the user already entered up front. Nil when not in host-passphrase mode.
    private var hostPassphrase: String?

    private init() {}

    // MARK: - Debug Logging

    private func debugLog(_ message: String) {
        Logger.debug(message, context: "TrezorUiHandler")
        TrezorDebugLog.shared.log("[UI] \(message)")
    }

    // MARK: - Wallet Mode API

    /// Set which wallet to open. The caller is responsible for resetting the device
    /// session (disconnect/reconnect) so the new mode takes effect — the Trezor caches
    /// the passphrase for the lifetime of a session.
    ///
    /// `hostPassphrase` is only meaningful for `.passphraseHost` — it is the passphrase
    /// the user entered on the phone up front.
    func setWalletMode(_ mode: TrezorWalletMode, hostPassphrase: String = "") {
        modeLock.lock()
        walletMode = mode
        self.hostPassphrase = mode == .passphraseHost ? hostPassphrase : nil
        modeLock.unlock()
        debugLog("Wallet mode set to \(mode)")
    }

    /// The wallet the current mode/passphrase selects, for binding to a THP session when
    /// `connect` runs. Mirrors `onPassphraseRequest` so THP (bound at session creation)
    /// and legacy devices (answered mid-operation) stay in lockstep from one source of
    /// truth. Reconnects derive their wallet from here, so it reflects the selection until
    /// the next `setWalletMode` or disconnect.
    func currentSelection() -> WalletSelection {
        modeLock.lock()
        defer { modeLock.unlock() }

        switch walletMode {
        case .standard:
            return .standard
        case .passphraseDevice:
            return .onDevice
        case .passphraseHost:
            if let cached = hostPassphrase, !cached.isEmpty {
                return .hidden(passphrase: cached)
            }
            return .standard
        }
    }

    // MARK: - TrezorUiCallback Implementation

    func onPinRequest() -> String {
        debugLog("onPinRequest: waiting for user input...")

        pinLock.lock()
        submittedPin = ""
        pinLock.unlock()

        // Notify UI to show PIN entry dialog
        DispatchQueue.main.async {
            self.needsPinPublisher.send()
        }

        // Block and wait for user to enter PIN
        let timeout = DispatchTime.now() + Self.timeoutSeconds
        let result = pinSemaphore.wait(timeout: timeout)

        if result == .timedOut {
            debugLog("onPinRequest: timed out")
            return ""
        }

        pinLock.lock()
        let pin = submittedPin
        pinLock.unlock()

        debugLog("onPinRequest: \(pin.isEmpty ? "cancelled" : "received")")
        return pin
    }

    func onPassphraseRequest(onDevice: Bool) -> PassphraseResponse {
        // Device-mandated on-device entry always wins, regardless of mode.
        if onDevice {
            debugLog("onPassphraseRequest: on-device (device-mandated), deferring to Trezor")
            return .onDevice
        }

        modeLock.lock()
        let mode = walletMode
        let cached = hostPassphrase
        modeLock.unlock()

        switch mode {
        case .standard:
            debugLog("onPassphraseRequest: standard wallet")
            return .standard
        case .passphraseDevice:
            debugLog("onPassphraseRequest: passphrase wallet (on-device entry), deferring to Trezor")
            return .onDevice
        case .passphraseHost:
            // Answer from the passphrase entered up front (the same value bound to the
            // THP session). Empty/absent == the standard wallet.
            if let cached, !cached.isEmpty {
                debugLog("onPassphraseRequest: host passphrase wallet, answering with pre-entered passphrase")
                return .hidden(value: cached)
            }
            debugLog("onPassphraseRequest: host passphrase empty, answering with standard")
            return .standard
        }
    }

    // MARK: - PIN Submit/Cancel Methods

    /// Called by ViewModel when user submits PIN
    func submitPin(_ pin: String) {
        debugLog("submitPin")
        pinLock.lock()
        submittedPin = pin
        pinLock.unlock()
        pinSemaphore.signal()
    }

    /// Called by ViewModel when user cancels PIN entry
    func cancelPin() {
        debugLog("cancelPin")
        pinLock.lock()
        submittedPin = ""
        pinLock.unlock()
        pinSemaphore.signal()
    }
}
