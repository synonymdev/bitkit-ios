import BitkitCore
import Combine
import Foundation

/// Implementation of TrezorUiCallback protocol for PIN and passphrase handling.
/// Blocks the Rust calling thread until the user responds via the UI,
/// following the same semaphore pattern as TrezorTransport.getPairingCode().
final class TrezorUiHandler: TrezorUiCallback {
    static let shared = TrezorUiHandler()

    // MARK: - PIN Handling

    /// Publisher to notify UI when PIN entry is needed
    let needsPinPublisher = PassthroughSubject<Void, Never>()

    private var submittedPin: String = ""
    private let pinLock = NSLock()
    private let pinSemaphore = DispatchSemaphore(value: 0)

    // MARK: - Passphrase Handling

    /// Publisher to notify UI when passphrase entry is needed.
    /// Bool parameter: true if passphrase should be entered on the device itself.
    let needsPassphrasePublisher = PassthroughSubject<Bool, Never>()

    private var submittedPassphrase: String = ""
    private let passphraseLock = NSLock()
    private let passphraseSemaphore = DispatchSemaphore(value: 0)

    /// Tracks whether a passphrase request is actively blocking,
    /// to prevent stale semaphore signals from dismissConfirmOnDevice().
    private var isAwaitingPassphrase = false
    private let awaitingLock = NSLock()

    /// Timeout for PIN/passphrase entry (2 minutes)
    private static let timeoutSeconds: TimeInterval = 120

    private init() {}

    // MARK: - Debug Logging

    private func debugLog(_ message: String) {
        Logger.debug(message, context: "TrezorUiHandler")
        TrezorDebugLog.shared.log("[UI] \(message)")
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

    func onPassphraseRequest(onDevice: Bool) -> String {
        debugLog("onPassphraseRequest: onDevice=\(onDevice), waiting for user input...")

        passphraseLock.lock()
        submittedPassphrase = ""
        passphraseLock.unlock()

        awaitingLock.lock()
        isAwaitingPassphrase = true
        awaitingLock.unlock()

        // Notify UI
        DispatchQueue.main.async {
            self.needsPassphrasePublisher.send(onDevice)
        }

        // Block and wait for user response
        let timeout = DispatchTime.now() + Self.timeoutSeconds
        let result = passphraseSemaphore.wait(timeout: timeout)

        awaitingLock.lock()
        isAwaitingPassphrase = false
        awaitingLock.unlock()

        if result == .timedOut {
            debugLog("onPassphraseRequest: timed out")
            return ""
        }

        if onDevice {
            // For on-device entry, return any non-empty string to acknowledge
            debugLog("onPassphraseRequest(onDevice): acknowledged")
            return "ok"
        }

        passphraseLock.lock()
        let passphrase = submittedPassphrase
        passphraseLock.unlock()

        debugLog("onPassphraseRequest: \(passphrase.isEmpty ? "cancelled" : "received")")
        return passphrase
    }

    // MARK: - UI Submit/Cancel Methods

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

    /// Called by ViewModel when user submits passphrase
    func submitPassphrase(_ passphrase: String) {
        debugLog("submitPassphrase")
        passphraseLock.lock()
        submittedPassphrase = passphrase
        passphraseLock.unlock()
        passphraseSemaphore.signal()
    }

    /// Called by ViewModel when user cancels passphrase entry
    func cancelPassphrase() {
        debugLog("cancelPassphrase")
        passphraseLock.lock()
        submittedPassphrase = ""
        passphraseLock.unlock()
        passphraseSemaphore.signal()
    }

    /// Called by ViewModel when user acknowledges on-device passphrase entry.
    /// Only signals if a passphrase request is actually pending.
    func acknowledgeOnDevicePassphrase() {
        awaitingLock.lock()
        let awaiting = isAwaitingPassphrase
        awaitingLock.unlock()

        guard awaiting else { return }

        debugLog("acknowledgeOnDevicePassphrase")
        passphraseSemaphore.signal()
    }
}
