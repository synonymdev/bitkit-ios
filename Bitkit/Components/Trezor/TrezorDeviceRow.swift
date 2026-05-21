import BitkitCore
import SwiftUI

/// Row displaying a discovered Trezor device
struct TrezorDeviceRow: View {
    let device: TrezorDeviceInfo
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        Button(action: {
            if !isConnecting {
                onConnect()
            }
        }) {
            HStack(spacing: 16) {
                // Device icon
                Image(systemName: transportIcon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Device info
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Text(transportLabel)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()

                // Connect indicator or chevron
                if isConnecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("Connect")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
    }

    private var displayName: String {
        if let label = device.label, !label.isEmpty {
            return label
        }
        return modelName
    }

    private var modelName: String {
        if let model = device.model {
            return "Trezor \(model)"
        }
        return "Trezor"
    }

    private var transportIcon: String {
        switch device.transportType {
        case .bluetooth:
            return "wave.3.right"
        case .usb:
            return "cable.connector"
        }
    }

    private var transportLabel: String {
        switch device.transportType {
        case .bluetooth:
            return "Bluetooth"
        case .usb:
            return "USB"
        }
    }
}

// MARK: - Known Device Row

/// Row displaying a previously connected (known) Trezor device
struct KnownDeviceRow: View {
    let device: TrezorKnownDevice
    let isConnecting: Bool
    let onConnect: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Tap area for connect
            Button(action: {
                if !isConnecting {
                    onConnect()
                }
            }) {
                HStack(spacing: 16) {
                    // Device icon
                    Image(systemName: device.transportType == "bluetooth" ? "wave.3.right" : "cable.connector")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Device info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.label ?? device.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)

                        Text(device.lastConnectedAt.relativeDescription)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                    }

                    Spacer()

                    if isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)

            // Forget button
            Button(action: onForget) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(10)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Date Helper

extension Date {
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Returns a relative description like "2 minutes ago"
    var relativeDescription: String {
        Self.relativeDateFormatter.localizedString(for: self, relativeTo: Date())
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorDeviceRow_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 16) {
                    TrezorDeviceRow(
                        device: TrezorDeviceInfo(
                            id: "ble:12345",
                            transportType: .bluetooth,
                            name: "Trezor Safe 5",
                            path: "ble:12345",
                            label: "My Trezor",
                            model: "Safe 5",
                            isBootloader: false
                        ),
                        isConnecting: false,
                        onConnect: {}
                    )

                    TrezorDeviceRow(
                        device: TrezorDeviceInfo(
                            id: "usb:001",
                            transportType: .usb,
                            name: "Trezor Model T",
                            path: "usb:001",
                            label: nil,
                            model: "Model T",
                            isBootloader: false
                        ),
                        isConnecting: true,
                        onConnect: {}
                    )
                }
                .padding()
            }
        }
    }
#endif
