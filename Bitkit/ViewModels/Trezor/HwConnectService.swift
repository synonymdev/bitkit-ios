import BitkitCore
import Foundation

/// Production `HwConnectServicing` over the vendor managers. iOS is Bluetooth only, so discovery runs
/// a Trezor scan and a Jade scan side by side. Pairing goes through `HwWalletManager`, which releases
/// the other vendor's session first and queues the pairing behind the other device operations.
@MainActor
struct HwConnectService: HwConnectServicing {
    let trezorManager: TrezorManager
    let jadeManager: JadeManager
    let hwWalletManager: HwWalletManager

    func scanForDevices() async throws -> [HwNearbyDevice] {
        async let trezorScan = scanTrezor()
        async let jadeScan = scanJade()
        let trezor = await trezorScan
        let jade = await jadeScan
        return try Self.nearbyDevices(trezor: trezor, jade: jade, isPaired: isPaired)
    }

    /// Unpaired devices of either vendor first, then the paired ones. A device that is already paired
    /// is only offered once no new one is found, so its passphrase wallets can be added afterwards;
    /// otherwise Add Hardware Wallet would search forever on the only device in range.
    ///
    /// A Jade scan fails quietly (core refuses to scan while it is busy with another request), so the
    /// search only fails when the Trezor scan failed and nothing was found.
    static func nearbyDevices(
        trezor: Result<[HwNearbyDevice], Error>,
        jade: Result<[HwNearbyDevice], Error>,
        isPaired: (HwNearbyDevice) -> Bool
    ) throws -> [HwNearbyDevice] {
        let found = ((try? trezor.get()) ?? []) + ((try? jade.get()) ?? [])
        if found.isEmpty, case let .failure(error) = trezor {
            throw error
        }
        let (paired, unpaired) = found.partitioned(by: isPaired)
        return unpaired + paired
    }

    private func scanTrezor() async -> Result<[HwNearbyDevice], Error> {
        await trezorManager.startScan()
        if let error = trezorManager.error {
            return .failure(AppError(message: error, debugMessage: nil))
        }
        return .success(trezorManager.devices.map { HwNearbyDevice(source: .trezor($0)) })
    }

    private func scanJade() async -> Result<[HwNearbyDevice], Error> {
        do {
            let devices = try await jadeManager.scan()
            return .success(devices.map { HwNearbyDevice(source: .jade($0)) })
        } catch {
            Logger.warn("Jade scan failed: \(error)", context: "HwConnectService")
            return .failure(error)
        }
    }

    /// A Jade counts as paired under the name it advertises too: after a reboot it comes back under a
    /// new Bluetooth identifier.
    func isPaired(_ device: HwNearbyDevice) -> Bool {
        switch device.source {
        case let .trezor(trezor):
            HwKnownDeviceStorage.isKnown(id: trezor.id, vendor: .trezor)
        case let .jade(jade):
            jadeManager.hasKnownDevice(deviceId: jade.path, advertisedName: jade.name)
        }
    }

    func connect(to device: HwNearbyDevice) async throws -> HwConnectResult {
        switch device.source {
        case let .trezor(trezor):
            try await connectTrezor(trezor)
        case let .jade(jade):
            try await connectJade(jade)
        }
    }

    /// `TrezorManager.connect` returns nothing and stores its state, so success is read from its
    /// `connectedDevice` and `deviceFeatures`, and its error is surfaced otherwise.
    private func connectTrezor(_ device: TrezorDeviceInfo) async throws -> HwConnectResult {
        try await hwWalletManager.withVendorSession(.trezor) {
            await trezorManager.connect(device: device)
            guard let connected = trezorManager.connectedDevice, connected.id == device.id else {
                throw AppError(message: trezorManager.error ?? t("hardware__connect_error"), debugMessage: nil)
            }
            let walletId = trezorManager.connectedWalletId
            let deviceDefaultName = resolveHwWalletName(
                label: connected.label ?? trezorManager.deviceFeatures?.label,
                model: connected.model ?? trezorManager.deviceFeatures?.model
            )
            return HwConnectResult(
                deviceId: connected.id,
                walletId: walletId,
                name: Self.pairedName(
                    walletId: walletId,
                    storedEntries: HwKnownDeviceStorage.loadAll(),
                    deviceDefaultName: deviceDefaultName
                ),
                deviceDefaultName: deviceDefaultName
            )
        }
    }

    private func connectJade(_ device: JadeDeviceInfo) async throws -> HwConnectResult {
        let connected = try await hwWalletManager.withVendorSession(.blockstream) {
            try await jadeManager.connect(path: device.path)
        }
        let deviceDefaultName = resolveHwWalletName(label: nil, model: connected.model, vendor: .blockstream)
        return HwConnectResult(
            deviceId: connected.id,
            walletId: connected.walletId,
            name: Self.pairedName(
                walletId: connected.walletId,
                storedEntries: HwKnownDeviceStorage.loadAll(),
                deviceDefaultName: deviceDefaultName
            ),
            deviceDefaultName: deviceDefaultName,
            vendor: .blockstream
        )
    }

    /// The name to show the paired step under, so re-pairing doesn't appear to rename the wallet.
    ///
    /// Read from the store rather than from the published wallet list: connecting has just written
    /// this identity's entry, and the tiles only catch up on the next device push. A wallet that was
    /// removed and is now being re-added is not in that list at all, so its name (restored from a
    /// backup or kept through the removal, and adopted onto the entry a moment ago) would fall back
    /// to the device's own. Finishing the step then persists that fallback over it.
    static func pairedName(
        walletId: String?,
        storedEntries: [HwKnownDevice],
        deviceDefaultName: String
    ) -> String {
        storedName(walletId: walletId, storedEntries: storedEntries) ?? deviceDefaultName
    }

    /// The Bitkit-side name stored for `walletId`, or nil when it has none of its own.
    static func storedName(walletId: String?, storedEntries: [HwKnownDevice]) -> String? {
        guard let walletId,
              let label = storedEntries.first(where: { $0.resolvedWalletId == walletId })?.customLabel,
              !label.isEmpty
        else {
            return nil
        }
        return label
    }

    func connectWithPassphrase(deviceId: String, passphrase: String) async throws -> String {
        try await hwWalletManager.connectWithPassphrase(deviceId: deviceId, passphrase: passphrase)
    }

    func storedName(forWallet walletId: String) -> String? {
        Self.storedName(walletId: walletId, storedEntries: HwKnownDeviceStorage.loadAll())
    }

    func setWalletLabel(walletId: String, label: String) {
        hwWalletManager.renameWallet(walletId: walletId, newName: label)
    }

    func cancelPairingCode() {
        trezorManager.cancelPairingCode()
    }

    /// The release runs in its own task, so it carries on after the sheet goes away.
    func cancelPendingConnection(to device: HwNearbyDevice) {
        switch device.source {
        case let .trezor(trezor):
            trezorManager.cancelPairingCode()
            Task { [trezorManager] in
                // A session another Trezor holds was not opened by this connect.
                if let connected = trezorManager.connectedDevice, connected.id != trezor.id {
                    return
                }
                await trezorManager.disconnectStaleSession(deviceId: trezor.id)
            }
        case let .jade(jade):
            Task { [jadeManager] in
                await jadeManager.cancelPendingConnection(deviceId: jade.path)
            }
        }
    }
}

private extension Array {
    /// Splits into (matching, rest), preserving order within each group.
    func partitioned(by isMatch: (Element) -> Bool) -> (matching: [Element], rest: [Element]) {
        reduce(into: ([Element](), [Element]())) { result, element in
            if isMatch(element) {
                result.0.append(element)
            } else {
                result.1.append(element)
            }
        }
    }
}
