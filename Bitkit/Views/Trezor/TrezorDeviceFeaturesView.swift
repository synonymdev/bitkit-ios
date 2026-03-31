import BitkitCore
import SwiftUI

/// Inline content for device features, used by expandable section.
struct TrezorDeviceFeaturesContent: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        VStack(spacing: 24) {
            if let features = trezor.deviceFeatures {
                FirmwareSection(features: features)
                SecuritySection(features: features)
                IdentifiersSection(features: features, device: trezor.connectedDevice)
                ActionsSection()
            } else {
                NoFeaturesView()
            }
        }
    }
}

/// Full-screen view displaying detailed device features (used for previews)
struct TrezorDeviceFeaturesView: View {
    var body: some View {
        ScrollView {
            TrezorDeviceFeaturesContent()
                .padding(16)
        }
        .background(Color.black)
        .navigationTitle("Device Info")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Device Header Section

private struct DeviceHeaderSection: View {
    let features: TrezorFeatures

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 48))
                .foregroundColor(.white)
                .padding(24)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())

            VStack(spacing: 4) {
                Text(features.label ?? "Trezor")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                if let model = features.model {
                    Text("Model \(model)")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Firmware Section

private struct FirmwareSection: View {
    let features: TrezorFeatures

    var body: some View {
        InfoSection(title: "Firmware") {
            if let major = features.majorVersion,
               let minor = features.minorVersion,
               let patch = features.patchVersion
            {
                InfoRow(label: "Version", value: "\(major).\(minor).\(patch)")
            }

            if let vendor = features.vendor {
                InfoRow(label: "Vendor", value: vendor)
            }
        }
    }
}

// MARK: - Security Section

private struct SecuritySection: View {
    let features: TrezorFeatures

    var body: some View {
        InfoSection(title: "Security") {
            TrezorStatusRow(
                label: "PIN Protection",
                isEnabled: features.pinProtection ?? false
            )

            TrezorStatusRow(
                label: "Passphrase Protection",
                isEnabled: features.passphraseProtection ?? false
            )

            TrezorStatusRow(
                label: "Initialized",
                isEnabled: features.initialized ?? false
            )

            TrezorStatusRow(
                label: "Needs Backup",
                isEnabled: features.needsBackup ?? false,
                positiveColor: .orange
            )
        }
    }
}

// MARK: - Identifiers Section

private struct IdentifiersSection: View {
    let features: TrezorFeatures
    let device: TrezorDeviceInfo?

    var body: some View {
        InfoSection(title: "Device Identifiers") {
            if let deviceId = features.deviceId {
                InfoRow(label: "Device ID", value: deviceId, isMonospaced: true)
            }

            if let path = device?.path {
                InfoRow(label: "Path", value: path, isMonospaced: true)
            }
        }
    }
}

// MARK: - Actions Section

private struct ActionsSection: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        VStack(spacing: 12) {
            Button(action: {
                Task {
                    await trezor.clearCredentials()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text("Clear Stored Credentials")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Text("This will require re-pairing via Bluetooth on next connection")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - No Features View

private struct NoFeaturesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Device features not available")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(48)
    }
}

// MARK: - Info Section Container

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))

            VStack(spacing: 8) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Info Row

private struct InfoRow: View {
    let label: String
    let value: String
    var isMonospaced: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            Text(value)
                .font(.system(size: 14, design: isMonospaced ? .monospaced : .default))
                .foregroundColor(.white)
                .lineLimit(1)
        }
    }
}

// MARK: - Trezor Status Row

private struct TrezorStatusRow: View {
    let label: String
    let isEnabled: Bool
    var positiveColor: Color = .green

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(isEnabled ? positiveColor : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)

                Text(isEnabled ? "Yes" : "No")
                    .font(.system(size: 14))
                    .foregroundColor(isEnabled ? positiveColor : .white.opacity(0.6))
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorDeviceFeaturesView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorDeviceFeaturesView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
