import BitkitCore
@preconcurrency import Combine
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
///
/// `@unchecked`: the Rust FFI calls in on its own threads; the PIN request state is guarded by `pinLock`,
/// `walletMode` and `hostPassphrase` by `modeLock`.
final class TrezorUiHandler: TrezorUiCallback, @unchecked Sendable {
    static let shared = TrezorUiHandler()

    // MARK: - PIN Handling

    private let pinRequestId = CurrentValueSubject<Int?, Never>(nil)

    /// The id of the PIN request core waits on, or nil once it ends, delivered on the main queue. Every request gets a new
    /// id, because the device scrambles its PIN matrix again each time.
    var pinRequestIds: AnyPublisher<Int?, Never> {
        pinRequestId.eraseToAnyPublisher()
    }

    private var pinRequest: PinRequest?
    private var nextPinRequestId = 1
    private var pinRefusals = 0
    private let pinLock = NSLock()

    private let pinTimeout: TimeInterval

    // MARK: - Wallet Mode / Passphrase Selection

    private let modeLock = NSLock()
    private var walletMode: TrezorWalletMode = .standard

    /// Host passphrase captured when `.passphraseHost` is selected. Mirrors the value
    /// bound to the THP session so legacy (non-THP) devices — which re-request the
    /// passphrase mid-operation via `onPassphraseRequest` — can be answered from the
    /// value the user already entered up front. Nil when not in host-passphrase mode.
    private var hostPassphrase: String?

    init(pinTimeout: TimeInterval = 120) {
        self.pinTimeout = pinTimeout
    }

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
        guard let request = startPinRequest() else {
            debugLog("onPinRequest: refused")
            return ""
        }
        debugLog("onPinRequest: waiting for user input on request \(request.id)...")

        // Block and wait for user to enter PIN
        if request.semaphore.wait(timeout: .now() + pinTimeout) == .timedOut {
            debugLog("onPinRequest: request \(request.id) timed out")
        }

        // Dropped with the request it answers, so a late answer never reaches the next one
        let pin = pinLock.withLock {
            if pinRequest === request {
                clearPinRequest()
            }
            return request.pin
        }
        debugLog("onPinRequest: request \(request.id) \(pin.isEmpty ? "cancelled" : "received")")
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

    /// Answers PIN request `requestId` with the matrix positions entered; an answer to any other request is dropped.
    func submitPin(_ pin: String, requestId: Int) {
        pinLock.withLock {
            guard let request = pinRequest, request.id == requestId else {
                debugLog("submitPin: dropped for request \(requestId)")
                return
            }
            debugLog("submitPin: request \(requestId)")
            answer(request, with: pin)
        }
    }

    /// Cancels PIN request `requestId`, or whichever request is pending when nil, so the device call ends now.
    func cancelPin(requestId: Int?) {
        pinLock.withLock {
            guard let request = pinRequest, requestId == nil || request.id == requestId else { return }
            debugLog("cancelPin: request \(request.id)")
            answer(request, with: "")
        }
    }

    /// Answers every PIN request with an empty PIN at once, publishing none, until a matching `allowPinRequests()`, so a
    /// connect that reaches its PIN prompt during a wallet wipe ends now instead of waiting for an entry nobody makes.
    func refusePinRequests() {
        pinLock.withLock { pinRefusals += 1 }
    }

    func allowPinRequests() {
        pinLock.withLock { pinRefusals = max(pinRefusals - 1, 0) }
    }

    private func startPinRequest() -> PinRequest? {
        pinLock.withLock {
            // A device asks for one PIN at a time, so a request still pending is stale
            if let stale = pinRequest {
                answer(stale, with: "")
            }
            guard pinRefusals == 0 else { return nil }
            let request = PinRequest(id: nextPinRequestId)
            nextPinRequestId += 1
            pinRequest = request
            publishPinRequestId(request.id)
            return request
        }
    }

    /// Callers hold `pinLock`.
    private func answer(_ request: PinRequest, with pin: String) {
        request.pin = pin
        clearPinRequest()
        request.semaphore.signal()
    }

    /// Callers hold `pinLock`.
    private func clearPinRequest() {
        pinRequest = nil
        publishPinRequestId(nil)
    }

    /// Callers hold `pinLock`, so the ids reach the main queue in the order the requests started and ended.
    private func publishPinRequestId(_ id: Int?) {
        DispatchQueue.main.async {
            self.pinRequestId.send(id)
        }
    }

    private final class PinRequest {
        let id: Int
        let semaphore = DispatchSemaphore(value: 0)
        var pin = ""

        init(id: Int) {
            self.id = id
        }
    }
}
