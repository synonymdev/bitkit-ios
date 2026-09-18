import BitkitCore
import Foundation

/// Result of a successful hardware-wallet connect: the persisted known-device id, the wallet
/// identity the session opened (nil until its accounts resolve), and its resolved display name.
struct HwConnectResult: Equatable {
    let deviceId: String
    let walletId: String?
    /// Name of the identity this session opened: its Bitkit-side label once it has one.
    let name: String
    /// The device's own name, from its label/model. A passphrase wallet has no label of its own
    /// until the user gives it one, so this is what its step is prefilled with; the label of the
    /// identity that happened to be open before it is not its name.
    let deviceDefaultName: String
    let vendor: HwWalletVendor

    init(
        deviceId: String,
        walletId: String?,
        name: String,
        deviceDefaultName: String? = nil,
        vendor: HwWalletVendor = .trezor
    ) {
        self.deviceId = deviceId
        self.walletId = walletId
        self.name = name
        self.deviceDefaultName = deviceDefaultName ?? name
        self.vendor = vendor
    }
}

/// A hardware wallet a scan found nearby. It carries the record its vendor's scan returned, so
/// connecting dials the device exactly as it was found.
struct HwNearbyDevice: Equatable, Identifiable {
    enum Source: Equatable {
        case trezor(TrezorDeviceInfo)
        case jade(JadeDeviceInfo)
    }

    let source: Source

    var vendor: HwWalletVendor {
        switch source {
        case .trezor: .trezor
        case .jade: .blockstream
        }
    }

    /// A Jade is known by its path until connecting reads its identity from the device.
    var id: String {
        switch source {
        case let .trezor(device): device.id
        case let .jade(device): device.path
        }
    }

    var path: String {
        switch source {
        case let .trezor(device): device.path
        case let .jade(device): device.path
        }
    }

    var name: String? {
        switch source {
        case let .trezor(device): device.name
        case let .jade(device): device.name
        }
    }

    /// A Jade reports its model only once connected.
    var model: String? {
        switch source {
        case let .trezor(device): device.model
        case .jade: nil
        }
    }
}

/// Device discovery/connection seam the Connect Hardware flow drives. `HwConnectService` is the
/// production adapter over the vendor managers; tests inject a fake so the flow can be exercised
/// without the BLE stack.
@MainActor
protocol HwConnectServicing {
    /// Reachable devices of every vendor, unpaired first. Discovery normally hides paired devices; one
    /// is offered as a fallback so its passphrase wallets can be added after the initial pairing.
    func scanForDevices() async throws -> [HwNearbyDevice]
    func connect(to device: HwNearbyDevice) async throws -> HwConnectResult
    /// Opens the hidden wallet the passphrase unlocks and starts watching it; returns its wallet id.
    func connectWithPassphrase(deviceId: String, passphrase: String) async throws -> String
    /// The Bitkit-side name already stored for `walletId`, or nil when it has none.
    func storedName(forWallet walletId: String) -> String?
    func setWalletLabel(walletId: String, label: String)
    func cancelPairingCode()
    /// Stops a connect in flight to `device` and releases its session. A task cancel alone never
    /// reaches a Jade waiting for its PIN, and a Trezor session opened for a pairing the user left
    /// must not linger.
    func cancelPendingConnection(to device: HwNearbyDevice)
}

/// Backs the Connect Hardware bottom-sheet flow (Intro → Searching → Found → Paired). Drives device
/// discovery, connection and the Bitkit-side funds label through an `HwConnectServicing`, exposing a
/// single `phase` the sheet renders. The one-time pairing code, when the device requests it during
/// connect, is surfaced inline by moving to `.pairCode`. Reactivity to `showPairingCode`/`wallets`
/// lives in the sheet (idiomatic `.onChange`), which forwards changes via `onPairingCodeRequested()`
/// / `onWalletsUpdated(_:)`.
///
/// From the paired step the user can add the passphrase (hidden) wallets of the same device, each
/// becoming its own watched identity with its own label and balance.
@Observable
@MainActor
final class HwConnectViewModel {
    enum Phase: Hashable {
        case intro
        case searching
        case found
        case paired
        case passphrase
        case passphrasePaired
        case pairCode
    }

    static let deviceLabelMaxLength = 50
    private static let scanInterval: Duration = .seconds(2)

    // MARK: - Published state

    private(set) var phase: Phase = .intro
    private(set) var isConnecting = false
    private(set) var foundDevice: HwNearbyDevice?
    /// Vendor of the device being paired, which decides the copy, illustration and steps shown.
    private(set) var vendor: HwWalletVendor = .trezor
    /// A Jade being connected is waiting for its PIN on the device.
    private(set) var isUnlocking = false
    private(set) var foundDeviceModel = ""
    private(set) var pairedDeviceId: String?
    /// Identity paired on `pairedDeviceId`; resolved once its watch-only wallet is known.
    private(set) var pairedWalletId: String?
    private(set) var deviceName = ""
    /// The paired device's own name, kept apart from `deviceName` so a wallet the user renamed does
    /// not lend its label to the next identity opened on the same device.
    private(set) var deviceDefaultName = ""
    private(set) var balanceSats: UInt64 = 0
    private(set) var labelInput = ""
    /// Held only until the device answers; the passphrase is never persisted or logged.
    private(set) var passphraseInput = ""
    private(set) var isSubmittingPassphrase = false
    private(set) var errorMessage: String?

    /// Invoked when the user taps Finish after the label is persisted, so the host can dismiss the
    /// sheet and return to Home. Set by the sheet.
    var onFinished: (() -> Void)?

    // MARK: - Dependencies & internal state

    private let service: HwConnectServicing
    private var labelInitialized = false
    private var searchTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    init(service: HwConnectServicing) {
        self.service = service
    }

    // MARK: - Intro → Searching

    func onIntroContinue() {
        errorMessage = nil
        phase = .searching
        startSearching()
    }

    private func startSearching() {
        guard searchTask == nil else { return }
        errorMessage = nil
        searchTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do {
                    let devices = try await service.scanForDevices()
                    if Task.isCancelled {
                        return
                    }
                    errorMessage = nil
                    if let device = devices.first {
                        onDeviceFound(device)
                        return
                    }
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    errorMessage = t("hardware__search_error")
                }
                do {
                    try await Task.sleep(for: Self.scanInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func onDeviceFound(_ device: HwNearbyDevice) {
        searchTask?.cancel()
        searchTask = nil
        foundDevice = device
        vendor = device.vendor
        foundDeviceModel = resolveHwWalletName(label: nil, model: device.model, vendor: device.vendor)
        errorMessage = nil
        phase = .found
    }

    // MARK: - Found → Connect → Paired

    func onConnect() {
        guard let device = foundDevice, connectTask == nil else { return }
        searchTask?.cancel()
        searchTask = nil
        isConnecting = true
        errorMessage = nil
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.connect(to: device)
                if Task.isCancelled {
                    return
                }
                onConnected(result)
            } catch {
                if Task.isCancelled {
                    return
                }
                onConnectFailed(error)
            }
            connectTask = nil
        }
    }

    private func onConnected(_ result: HwConnectResult) {
        isConnecting = false
        isUnlocking = false
        vendor = result.vendor
        pairedDeviceId = result.deviceId
        // The device may hold several identities, so take the one this session opened rather than
        // any wallet sharing its transport id.
        pairedWalletId = result.walletId
        deviceName = result.name
        deviceDefaultName = result.deviceDefaultName
        labelInput = result.name
        // Until the identity resolves, the prefill is only the device's own name; let a wallet
        // emission refine it.
        labelInitialized = result.walletId != nil
        errorMessage = nil
        phase = .paired
    }

    private func onConnectFailed(_ error: Error) {
        isConnecting = false
        isUnlocking = false
        errorMessage = connectErrorMessage(for: error)
        phase = .found
    }

    /// A Jade failure keeps its own copy (a wrong PIN, the pinserver, a stale Bluetooth bond), which
    /// the generic connect message would hide.
    private func connectErrorMessage(for error: Error) -> String {
        guard vendor == .blockstream else {
            return (error as? AppError)?.message ?? t("hardware__connect_error")
        }
        if let jadeMessage = HwErrorPresenter.jadeMessage(from: error) {
            return jadeMessage
        }
        if let appError = error as? AppError, !appError.isGeneric {
            return appError.message
        }
        return t("hardware__connect_error")
    }

    /// The Trezor asked for its one-time pairing code mid-connect; surface the inline step. Only
    /// while a Trezor connect is in flight, so a stray flag can't hijack the flow.
    func onPairingCodeRequested() {
        guard isConnecting, vendor == .trezor else { return }
        phase = .pairCode
    }

    /// The device started or stopped waiting for its PIN. The hint only belongs to a Jade this flow is
    /// connecting; a background reconnect never unlocks.
    func onUnlockingChanged(_ isDeviceUnlocking: Bool) {
        isUnlocking = isDeviceUnlocking && isConnecting && vendor == .blockstream
    }

    // MARK: - Paired

    /// The paired wallet's aggregated balance/name landed; reflect it on the Paired step.
    func onWalletsUpdated(_ wallets: [HwWallet]) {
        guard let deviceId = pairedDeviceId else { return }
        guard let wallet = pairedWallet(in: wallets, deviceId: deviceId) else { return }

        pairedWalletId = wallet.id
        deviceName = wallet.name
        balanceSats = wallet.balanceSats
        if !labelInitialized {
            labelInput = wallet.name
        }
        labelInitialized = true
    }

    /// The wallet the paired step is showing.
    private func pairedWallet(in wallets: [HwWallet], deviceId: String) -> HwWallet? {
        if let pairedWalletId {
            // The store publishes a newly watched identity asynchronously: wait for it rather than
            // falling back to another wallet of the same device and reporting its name, balance and
            // label as this one's.
            return wallets.first { $0.id == pairedWalletId }
        }
        // The connect could not resolve which identity it opened. One wallet reading as connected
        // means it resolved afterwards; failing that, a device holding a single identity is
        // unambiguous. Anything else is a guess, and guessing here shows a sibling wallet's balance
        // and renames that wallet on Finish — a device with an unresolved session reports every one
        // of its identities as connected, so there is nothing to tell them apart by.
        let onDevice = wallets.filter { $0.deviceIds.contains(deviceId) }
        let connected = onDevice.filter(\.isConnected)
        if connected.count == 1 {
            return connected.first
        }
        return onDevice.count == 1 ? onDevice.first : nil
    }

    func onLabelChange(_ value: String) {
        // Once the user types, the field is theirs: a wallet emission arriving late must not
        // overwrite what they entered.
        labelInitialized = true
        labelInput = String(value.prefix(Self.deviceLabelMaxLength))
    }

    // MARK: - Passphrase (hidden) wallets

    /// Each identity is labelled on its own paired step, so the one being left is persisted before
    /// the next passphrase wallet takes over the field.
    func onPassphraseClick() {
        guard vendor.supportsPassphraseWallets else { return }
        persistLabel()
        passphraseInput = ""
        errorMessage = nil
        phase = .passphrase
    }

    func onPassphraseChange(_ value: String) {
        passphraseInput = value
    }

    /// Leaves the passphrase step without keeping what was typed.
    func onPassphraseBack() {
        passphraseInput = ""
        errorMessage = nil
        phase = .paired
    }

    /// Opens the hidden wallet the entered passphrase unlocks and watches it as its own identity.
    /// The passphrase is dropped from state as soon as the device answers: it lives in the Trezor
    /// session, never in Bitkit.
    func onPassphraseSubmit() {
        guard vendor.supportsPassphraseWallets,
              let deviceId = pairedDeviceId,
              !passphraseInput.isEmpty,
              connectTask == nil
        else { return }
        let passphrase = passphraseInput
        isSubmittingPassphrase = true
        errorMessage = nil

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let walletId = try await service.connectWithPassphrase(deviceId: deviceId, passphrase: passphrase)
                if Task.isCancelled {
                    return
                }
                onPassphraseWalletAdded(walletId)
            } catch {
                if Task.isCancelled {
                    return
                }
                onPassphraseFailed(error)
            }
            connectTask = nil
        }
    }

    private func onPassphraseWalletAdded(_ walletId: String) {
        isSubmittingPassphrase = false
        passphraseInput = ""
        pairedWalletId = walletId
        balanceSats = 0
        // A brand-new identity carries no label of its own, so it shows the device's name until the
        // wallet is published and that emission refines the prefill; once it resolves the field is
        // the user's to edit. One being added back already has its name on the entry that opening it
        // just wrote — a name restored from a backup or kept through its removal — so take it now
        // rather than showing the device's own for as long as the wallet takes to reach the list.
        let storedName = service.storedName(forWallet: walletId)
        deviceName = storedName ?? deviceDefaultName
        labelInitialized = storedName != nil
        labelInput = storedName ?? deviceDefaultName
        phase = .passphrasePaired
    }

    private func onPassphraseFailed(_ error: Error) {
        isSubmittingPassphrase = false
        passphraseInput = ""
        errorMessage = Self.passphraseErrorMessage(for: error)
    }

    private static func passphraseErrorMessage(for error: Error) -> String {
        switch error {
        case HwPassphraseError.protectionDisabled: t("hardware__passphrase_disabled")
        case HwPassphraseError.alreadyAdded: t("hardware__passphrase_duplicate")
        default: error.isTrezorDeviceBusy()
            ? TrezorErrorPresenter.userMessage(from: error)
            : t("hardware__passphrase_error")
        }
    }

    func onFinish() {
        persistLabel()
        onFinished?()
    }

    private func persistLabel() {
        guard let walletId = pairedWalletId else {
            Logger.warn("Finished pairing before its identity resolved; label not saved", context: "HwConnectViewModel")
            return
        }
        service.setWalletLabel(walletId: walletId, label: labelInput)
    }

    // MARK: - Teardown

    /// Cancels a pending connect when the user backs out mid-connect, releasing the device it was
    /// opening. Nothing is released when no connect is in flight, so leaving the sheet after pairing
    /// keeps the session the flow just opened.
    func cancelConnect() {
        let wasConnecting = connectTask != nil || isConnecting
        connectTask?.cancel()
        connectTask = nil
        if wasConnecting {
            if let foundDevice {
                service.cancelPendingConnection(to: foundDevice)
            } else {
                service.cancelPairingCode()
            }
        }
        isConnecting = false
        isUnlocking = false
    }

    /// Called when the sheet is dismissed: stop scanning/connecting and drop any pending pairing.
    func reset() {
        searchTask?.cancel()
        searchTask = nil
        cancelConnect()
        passphraseInput = ""
        isSubmittingPassphrase = false
    }
}
