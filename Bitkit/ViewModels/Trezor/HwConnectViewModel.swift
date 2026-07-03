import BitkitCore
import Foundation

/// Result of a successful hardware-wallet connect: the persisted known-device id and its resolved
/// display name (from the device's own label/model).
struct HwConnectResult: Equatable {
    let deviceId: String
    let name: String
}

/// Device discovery/connection seam the Connect Hardware flow drives. `TrezorHwConnectService` is
/// the production adapter over `TrezorManager`; tests inject a fake so the flow can be exercised
/// without the BLE stack.
@MainActor
protocol HwConnectServicing {
    func scanForUnpairedDevices() async throws -> [TrezorDeviceInfo]
    func connect(to device: TrezorDeviceInfo) async throws -> HwConnectResult
    func setDeviceLabel(id: String, label: String)
    func cancelPairingCode()
}

/// Backs the Connect Hardware bottom-sheet flow (Intro → Searching → Found → Paired). Drives device
/// discovery, connection and the Bitkit-side funds label through an `HwConnectServicing`, exposing a
/// single `phase` the sheet renders. The one-time pairing code, when the device requests it during
/// connect, is surfaced inline by moving to `.pairCode`. Reactivity to `showPairingCode`/`wallets`
/// lives in the sheet (idiomatic `.onChange`), which forwards changes via `onPairingCodeRequested()`
/// / `onWalletsUpdated(_:)`.
@Observable
@MainActor
final class HwConnectViewModel {
    enum Phase: Hashable {
        case intro
        case searching
        case found
        case paired
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
    private(set) var deviceName = ""
    private(set) var balanceSats: UInt64 = 0
    private(set) var labelInput = ""
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
                    let devices = try await service.scanForUnpairedDevices()
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
                onConnectFailed()
            }
            connectTask = nil
        }
    }

    private func onConnected(_ result: HwConnectResult) {
        isConnecting = false
        pairedDeviceId = result.deviceId
        deviceName = result.name
        if !labelInitialized {
            labelInput = result.name
        }
        labelInitialized = true
        errorMessage = nil
        phase = .paired
    }

    private func onConnectFailed() {
        isConnecting = false
        errorMessage = t("hardware__connect_error")
        phase = .found
    }

    /// The device asked for its one-time pairing code mid-connect; surface the inline step. Only
    /// while a connect is in flight, so a stray flag can't hijack the flow.
    func onPairingCodeRequested() {
        guard isConnecting else { return }
        phase = .pairCode
    }

    // MARK: - Paired

    /// The connected wallet's aggregated balance/name landed; reflect it on the Paired step.
    func onWalletsUpdated(_ wallets: [HwWallet]) {
        guard let deviceId = pairedDeviceId else { return }
        guard let wallet = wallets.first(where: { $0.id == deviceId || $0.deviceIds.contains(deviceId) }) else { return }
        deviceName = wallet.name
        balanceSats = wallet.balanceSats
        if !labelInitialized {
            labelInput = wallet.name
        }
        labelInitialized = true
    }

    func onLabelChange(_ value: String) {
        labelInput = String(value.prefix(Self.deviceLabelMaxLength))
    }

    func onFinish() {
        if let deviceId = pairedDeviceId {
            service.setDeviceLabel(id: deviceId, label: labelInput)
        }
        onFinished?()
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
    }
}

/// Production `HwConnectServicing` over `TrezorManager`. iOS is BLE-only, so discovery is a single
/// BLE scan filtered to unpaired devices; `connect(to:)` reports success by inspecting the manager's
/// `connectedDevice`/`deviceFeatures` (its own `connect` returns void and stores state) and surfaces
/// the manager's error otherwise.
@MainActor
struct TrezorHwConnectService: HwConnectServicing {
    let trezorManager: TrezorManager

    func scanForUnpairedDevices() async throws -> [TrezorDeviceInfo] {
        await trezorManager.startScan()
        if let error = trezorManager.error {
            throw AppError(message: error, debugMessage: nil)
        }
        return trezorManager.devices.filter { !TrezorKnownDeviceStorage.isKnown(id: $0.id) }
    }

    func connect(to device: TrezorDeviceInfo) async throws -> HwConnectResult {
        await trezorManager.connect(device: device)
        guard let connected = trezorManager.connectedDevice else {
            throw AppError(message: trezorManager.error ?? t("hardware__connect_error"), debugMessage: nil)
        }
        let name = resolveHwWalletName(
            label: connected.label ?? trezorManager.deviceFeatures?.label,
            model: connected.model ?? trezorManager.deviceFeatures?.model
        )
        return HwConnectResult(deviceId: connected.id, name: name)
    }

    func setDeviceLabel(id: String, label: String) {
        trezorManager.renameDevice(id: id, newName: label)
    }

    func cancelPairingCode() {
        trezorManager.cancelPairingCode()
    }
}
