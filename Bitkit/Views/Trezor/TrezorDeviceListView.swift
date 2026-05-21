import BitkitCore
import CoreBluetooth
import SwiftUI

/// View displaying discovered Trezor devices
struct TrezorDeviceListView: View {
    @Environment(TrezorViewModel.self) private var trezor
    @State private var connectingDevicePath: String?

    /// Scanned devices that are NOT already in the known devices list
    private var nearbyDevices: [TrezorDeviceInfo] {
        let knownIds = Set(trezor.knownDevices.map(\.id))
        return trezor.devices.filter { !knownIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // Bluetooth status (don't show during initial .unknown state)
                    if trezor.bluetoothState != .poweredOn, trezor.bluetoothState != .unknown {
                        BluetoothStatusCard(state: trezor.bluetoothState)
                    }

                    // Auto-reconnect indicator
                    if trezor.isAutoReconnecting, let status = trezor.autoReconnectStatus {
                        AutoReconnectIndicator(status: status)
                    }

                    // Scanning indicator
                    if trezor.isScanning, !trezor.isAutoReconnecting {
                        ScanningIndicator()
                    }

                    // Known devices section
                    if !trezor.knownDevices.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("My Devices")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))

                            ForEach(trezor.knownDevices) { device in
                                KnownDeviceRow(
                                    device: device,
                                    isConnecting: connectingDevicePath == device.path
                                ) {
                                    connectToKnownDevice(device)
                                } onForget: {
                                    Task {
                                        await trezor.forgetDevice(id: device.id)
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
                    if !trezor.isScanning, !trezor.isAutoReconnecting,
                       trezor.knownDevices.isEmpty, trezor.devices.isEmpty
                    {
                        TrezorEmptyStateView()
                    }

                    // Error display
                    if let error = trezor.error {
                        ErrorCard(message: error)
                    }
                }
                .padding(16)
            }

            // Bottom action button
            if !trezor.isScanning, !trezor.isAutoReconnecting,
               trezor.bluetoothState == .poweredOn || trezor.bluetoothState == .unknown
            {
                Button(action: {
                    Task {
                        await trezor.startScan()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(trezor.devices.isEmpty ? "Scan for Devices" : "Scan Again")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
            }
        }
        .background(Color.black)
        .navigationTitle("Connect Trezor")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            trezor.loadKnownDevices()

            // Wait briefly for BLE state to settle if still unknown
            // (CBCentralManager fires centralManagerDidUpdateState async after creation)
            if trezor.bluetoothState == .unknown {
                for _ in 0 ..< 10 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    if trezor.bluetoothState != .unknown { break }
                }
            }

            guard trezor.bluetoothState == .poweredOn else { return }

            if !trezor.knownDevices.isEmpty {
                await trezor.autoReconnect()
            } else if trezor.devices.isEmpty {
                await trezor.startScan()
            }
        }
        .onDisappear {
            trezor.stopScan()
        }
    }

    private func connectToDevice(_ device: TrezorDeviceInfo) {
        connectingDevicePath = device.path

        Task {
            await trezor.connect(device: device)
            connectingDevicePath = nil
        }
    }

    private func connectToKnownDevice(_ knownDevice: TrezorKnownDevice) {
        connectingDevicePath = knownDevice.path

        Task {
            // Check if this device was found in the last scan
            if let scanned = trezor.devices.first(where: { $0.id == knownDevice.id }) {
                await trezor.connect(device: scanned)
            } else {
                // Need to scan first to find the device
                await trezor.startScan(clearExisting: false)
                if let scanned = trezor.devices.first(where: { $0.id == knownDevice.id }) {
                    await trezor.connect(device: scanned)
                } else {
                    trezor.error = "Device not found nearby. Make sure your Trezor is turned on."
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
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorDeviceListView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorDeviceListView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
