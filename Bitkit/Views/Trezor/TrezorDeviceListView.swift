import BitkitCore
import CoreBluetooth
import SwiftUI

/// View displaying discovered Trezor devices
struct TrezorDeviceListView: View {
    @Environment(TrezorManager.self) private var trezorManager
    @State private var connectingDevicePath: String?
    @State private var isWatcherExpanded = false

    /// Scanned devices that are NOT already in the known devices list
    private var nearbyDevices: [TrezorDeviceInfo] {
        let knownIds = Set(trezorManager.knownDevices.map(\.id))
        return trezorManager.devices.filter { !knownIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // Bluetooth status (don't show during initial .unknown state)
                    if !trezorManager.isBridgeModeEnabled, trezorManager.bluetoothState != .poweredOn, trezorManager.bluetoothState != .unknown {
                        BluetoothStatusCard(state: trezorManager.bluetoothState)
                    }

                    // Auto-reconnect indicator
                    if trezorManager.isAutoReconnecting, let status = trezorManager.autoReconnectStatus {
                        AutoReconnectIndicator(status: status)
                    }

                    // Scanning indicator
                    if trezorManager.isScanning, !trezorManager.isAutoReconnecting {
                        ScanningIndicator()
                    }

                    // Known devices section
                    if !trezorManager.knownDevices.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("My Devices")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))

                            ForEach(trezorManager.knownDevices) { device in
                                KnownDeviceRow(
                                    device: device,
                                    isConnecting: connectingDevicePath == device.path
                                ) {
                                    connectToKnownDevice(device)
                                } onForget: {
                                    Task {
                                        await trezorManager.forgetDevice(id: device.id)
                                    }
                                }
                            }
                        }
                    }

                    // Nearby (new) devices section
                    if !nearbyDevices.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Nearby Devices")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))

                            ForEach(nearbyDevices, id: \.path) { device in
                                TrezorDeviceRow(
                                    device: device,
                                    isConnecting: connectingDevicePath == device.path
                                ) {
                                    connectToDevice(device)
                                }
                            }
                        }
                    }

                    // Empty state
                    if !trezorManager.isScanning, !trezorManager.isAutoReconnecting,
                       trezorManager.knownDevices.isEmpty, trezorManager.devices.isEmpty
                    {
                        TrezorEmptyStateView()
                    }

                    // Error display
                    if let error = trezorManager.error {
                        ErrorCard(message: error)
                    }

                    // Event watcher — works without a connected device (subscribes to
                    // Electrum directly), so it is available from the device-list screen
                    // and keeps running across connects/disconnects.
                    TrezorExpandableSection(
                        title: "Event Watcher",
                        icon: "dot.radiowaves.left.and.right",
                        description: "Watch an xpub for live on-chain activity (no device required)",
                        accessibilityIdentifier: "TrezorSection-Watcher",
                        isExpanded: $isWatcherExpanded
                    ) {
                        TrezorWatcherContent()
                    }
                }
                .padding(16)
            }

            // Bottom action button
            if !trezorManager.isScanning, !trezorManager.isAutoReconnecting,
               trezorManager.isBridgeModeEnabled || trezorManager.bluetoothState == .poweredOn || trezorManager.bluetoothState == .unknown
            {
                Button(action: {
                    Task {
                        await trezorManager.startScan()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(trezorManager.devices.isEmpty ? "Scan for Devices" : "Scan Again")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("TrezorScanButton")
                .padding(16)
            }
        }
        .background(Color.black)
        .navigationTitle("Connect Trezor")
        .navigationBarTitleDisplayMode(.inline)
        .trezorAccessibilityAnchor("TrezorDeviceList")
        .task {
            trezorManager.loadKnownDevices()

            // Wait briefly for BLE state to settle if still unknown
            // (CBCentralManager fires centralManagerDidUpdateState async after creation)
            if trezorManager.bluetoothState == .unknown {
                for _ in 0 ..< 10 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    if trezorManager.bluetoothState != .unknown { break }
                }
            }

            guard trezorManager.isBridgeModeEnabled || trezorManager.bluetoothState == .poweredOn else { return }

            if !trezorManager.knownDevices.isEmpty {
                await trezorManager.autoReconnect()
            } else if trezorManager.devices.isEmpty {
                await trezorManager.startScan()
            }
        }
        .onDisappear {
            trezorManager.stopScan()
        }
    }

    private func connectToDevice(_ device: TrezorDeviceInfo) {
        connectingDevicePath = device.path

        Task {
            await trezorManager.connect(device: device)
            connectingDevicePath = nil
        }
    }

    private func connectToKnownDevice(_ knownDevice: TrezorKnownDevice) {
        connectingDevicePath = knownDevice.path

        Task {
            // Check if this device was found in the last scan
            if let scanned = trezorManager.devices.first(where: { $0.id == knownDevice.id }) {
                await trezorManager.connect(device: scanned)
            } else {
                // Need to scan first to find the device
                await trezorManager.startScan(clearExisting: false)
                if let scanned = trezorManager.devices.first(where: { $0.id == knownDevice.id }) {
                    await trezorManager.connect(device: scanned)
                } else {
                    trezorManager.error = "Device not found nearby. Make sure your Trezor is turned on."
                }
            }
            connectingDevicePath = nil
        }
    }
}

// MARK: - Subviews

private struct AutoReconnectIndicator: View {
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))

            Text(status)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(16)
        .trezorAccessibilityAnchor("TrezorAutoReconnectIndicator")
    }
}

private struct BluetoothStatusCard: View {
    let state: CBManagerState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bluetooth")
                .font(.system(size: 32))
                .foregroundColor(.orange)

            Text(statusTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Text(statusDescription)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .trezorAccessibilityAnchor("TrezorBluetoothStatus")
    }

    private var statusTitle: String {
        switch state {
        case .poweredOff:
            return "Bluetooth is Off"
        case .unauthorized:
            return "Bluetooth Unauthorized"
        case .unsupported:
            return "Bluetooth Unsupported"
        default:
            return "Bluetooth Unavailable"
        }
    }

    private var statusDescription: String {
        switch state {
        case .poweredOff:
            return "Please enable Bluetooth in Settings to connect to your Trezor."
        case .unauthorized:
            return "Bitkit needs Bluetooth permission to connect to your Trezor. Please enable it in Settings."
        case .unsupported:
            return "This device does not support Bluetooth Low Energy."
        default:
            return "Bluetooth is not available. Please check your device settings."
        }
    }
}

private struct ScanningIndicator: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)

            Text("Scanning for Trezor devices...")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))

            Text("Make sure your Trezor is turned on with Bluetooth enabled")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .trezorAccessibilityAnchor("TrezorScanningIndicator")
    }
}

private struct TrezorEmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))

            VStack(spacing: 8) {
                Text("No Devices Found")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                Text("Make sure your Trezor is turned on and Bluetooth is enabled.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .trezorAccessibilityAnchor("TrezorEmptyState")
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.red)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white)

            Spacer()
        }
        .padding(16)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .trezorAccessibilityAnchor("TrezorDeviceListError")
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorDeviceListView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorDeviceListView()
            }
            .environment(TrezorManager())
        }
    }
#endif
