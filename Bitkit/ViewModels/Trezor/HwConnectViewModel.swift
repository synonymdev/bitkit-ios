import BitkitCore
import Foundation

/// Result of a successful hardware-wallet connect: the persisted known-device id, the wallet
/// identity the session opened (nil until its accounts resolve), and its resolved display name.
struct HwConnectResult: Equatable {
    let deviceId: String
    let walletId: String?
    /// Name of the identity this session opened — its Bitkit-side label once it has one.
    let name: String
    /// The device's own name, from its label/model. A passphrase wallet has no label of its own
    /// until the user gives it one, so this is what its step is prefilled with — the label of the
    /// identity that happened to be open before it is not its name.
    let deviceDefaultName: String

    init(deviceId: String, walletId: String?, name: String, deviceDefaultName: String? = nil) {
        self.deviceId = deviceId
        self.walletId = walletId
        self.name = name
        self.deviceDefaultName = deviceDefaultName ?? name
    }
}

/// Device discovery/connection seam the Connect Hardware flow drives. `TrezorHwConnectService` is
/// the production adapter over `TrezorManager`; tests inject a fake so the flow can be exercised
/// without the BLE stack.
@MainActor
protocol HwConnectServicing {
    /// Reachable devices, unpaired first. Discovery normally hides paired devices; one is offered as
    /// a fallback so its passphrase wallets can be added after the initial pairing.
    func scanForDevices() async throws -> [TrezorDeviceInfo]
    func connect(to device: TrezorDeviceInfo) async throws -> HwConnectResult
    /// Opens the hidden wallet the passphrase unlocks and starts watching it; returns its wallet id.
    func connectWithPassphrase(deviceId: String, passphrase: String) async throws -> String
    func setWalletLabel(walletId: String, label: String)
    func cancelPairingCode()
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
    private(set) var foundDevice: TrezorDeviceInfo?
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
                    if Task.isCancelled { return }
                    errorMessage = nil
                    if let device = devices.first {
                        onDeviceFound(device)
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
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

    private func onDeviceFound(_ device: TrezorDeviceInfo) {
        searchTask?.cancel()
        searchTask = nil
        foundDevice = device
        foundDeviceModel = resolveHwWalletName(label: nil, model: device.model)
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
                if Task.isCancelled { return }
                onConnected(result)
            } catch {
                if Task.isCancelled { return }
                onConnectFailed(error)
            }
            connectTask = nil
        }
    }

    private func onConnected(_ result: HwConnectResult) {
        isConnecting = false
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
        errorMessage = (error as? AppError)?.message ?? t("hardware__connect_error")
        phase = .found
    }

    /// The device asked for its one-time pairing code mid-connect; surface the inline step. Only
    /// while a connect is in flight, so a stray flag can't hijack the flow.
    func onPairingCodeRequested() {
        guard isConnecting else { return }
        phase = .pairCode
    }

    // MARK: - Paired

    /// The paired wallet's aggregated balance/name landed; reflect it on the Paired step.
    func onWalletsUpdated(_ wallets: [HwWallet]) {
        guard let deviceId = pairedDeviceId else { return }
        let wallet: HwWallet? = if let pairedWalletId {
            // The store publishes a newly watched identity asynchronously: wait for it rather than
            // falling back to another wallet of the same device and reporting its name, balance and
            // label as this one's.
            wallets.first { $0.id == pairedWalletId }
        } else {
            wallets.first { $0.deviceIds.contains(deviceId) && $0.isConnected }
                ?? wallets.first { $0.deviceIds.contains(deviceId) }
        }
        guard let wallet else { return }

        pairedWalletId = wallet.id
        deviceName = wallet.name
        balanceSats = wallet.balanceSats
        if !labelInitialized {
            labelInput = wallet.name
        }
        labelInitialized = true
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
        guard let deviceId = pairedDeviceId, !passphraseInput.isEmpty, connectTask == nil else { return }
        let passphrase = passphraseInput
        isSubmittingPassphrase = true
        errorMessage = nil

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let walletId = try await service.connectWithPassphrase(deviceId: deviceId, passphrase: passphrase)
                if Task.isCancelled { return }
                onPassphraseWalletAdded(walletId)
            } catch {
                if Task.isCancelled { return }
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
        // the user's to edit.
        deviceName = deviceDefaultName
        labelInitialized = false
        labelInput = deviceDefaultName
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

    /// Cancels a pending connect/pairing-code request when the user backs out mid-connect.
    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        service.cancelPairingCode()
        isConnecting = false
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

/// Production `HwConnectServicing` over `TrezorManager`. iOS is BLE-only, so discovery is a single
/// BLE scan filtered to unpaired devices; `connect(to:)` reports success by inspecting the manager's
/// `connectedDevice`/`deviceFeatures` (its own `connect` returns void and stores state) and surfaces
/// the manager's error otherwise.
@MainActor
struct TrezorHwConnectService: HwConnectServicing {
    let trezorManager: TrezorManager
    let hwWalletManager: HwWalletManager

    func scanForDevices() async throws -> [TrezorDeviceInfo] {
        await trezorManager.startScan()
        if let error = trezorManager.error {
            throw AppError(message: error, debugMessage: nil)
        }
        // A device that is already paired is only offered once no new one is found, so its
        // passphrase wallets can be added afterwards — otherwise Add Hardware Wallet would search
        // forever on the only device in range.
        let (paired, unpaired) = trezorManager.devices.partitioned { TrezorKnownDeviceStorage.isKnown(id: $0.id) }
        return unpaired + paired
    }

    func connect(to device: TrezorDeviceInfo) async throws -> HwConnectResult {
        await trezorManager.connect(device: device)
        guard let connected = trezorManager.connectedDevice, connected.id == device.id else {
            throw AppError(message: trezorManager.error ?? t("hardware__connect_error"), debugMessage: nil)
        }
        let walletId = trezorManager.connectedWalletId
        let deviceDefaultName = resolveHwWalletName(
            label: connected.label ?? trezorManager.deviceFeatures?.label,
            model: connected.model ?? trezorManager.deviceFeatures?.model
        )
        // Show the name it was already saved under, so re-pairing doesn't appear to rename it.
        let stored = walletId.flatMap { id in hwWalletManager.wallets.first { $0.id == id } }
        return HwConnectResult(
            deviceId: connected.id,
            walletId: walletId,
            name: stored?.name ?? deviceDefaultName,
            deviceDefaultName: deviceDefaultName
        )
    }

    func connectWithPassphrase(deviceId: String, passphrase: String) async throws -> String {
        try await hwWalletManager.connectWithPassphrase(deviceId: deviceId, passphrase: passphrase)
    }

    func setWalletLabel(walletId: String, label: String) {
        trezorManager.renameWallet(walletId: walletId, newName: label)
    }

    func cancelPairingCode() {
        trezorManager.cancelPairingCode()
    }
}

private extension Array {
    /// Splits into (matching, rest), preserving order within each group.
    func partitioned(by isMatch: (Element) -> Bool) -> (matching: [Element], rest: [Element]) {
        reduce(into: ([Element](), [Element]())) { result, element in
            if isMatch(element) { result.0.append(element) } else { result.1.append(element) }
        }
    }
}
