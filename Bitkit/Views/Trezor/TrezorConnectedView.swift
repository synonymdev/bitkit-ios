import BitkitCore
import SwiftUI

/// View displayed when connected to a Trezor device.
/// Uses expandable sections instead of navigation to separate screens.
struct TrezorConnectedView: View {
    @Environment(TrezorViewModel.self) private var trezor
    @State private var isAddressExpanded = false
    @State private var isSignMessageExpanded = false
    @State private var isPublicKeyExpanded = false
    @State private var isBalanceLookupExpanded = false
    @State private var isDeviceInfoExpanded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Device card
                DeviceInfoCard(
                    device: trezor.connectedDevice,
                    features: trezor.deviceFeatures
                )

                // Expandable sections
                VStack(spacing: 12) {
                    TrezorExpandableSection(
                        title: "Get Address",
                        icon: "qrcode",
                        description: "Generate a receiving address",
                        isExpanded: $isAddressExpanded
                    ) {
                        TrezorAddressContent()
                    }

                    TrezorExpandableSection(
                        title: "Sign Message",
                        icon: "signature",
                        description: "Sign a message with your Trezor",
                        isExpanded: $isSignMessageExpanded
                    ) {
                        TrezorSignMessageContent()
                    }

                    TrezorExpandableSection(
                        title: "Public Key",
                        icon: "key",
                        description: "Get xpub and public key",
                        isExpanded: $isPublicKeyExpanded
                    ) {
                        TrezorPublicKeyContent()
                    }

                    TrezorExpandableSection(
                        title: "Balance Lookup",
                        icon: "magnifyingglass",
                        description: "Check balance & UTXOs for any address or xpub",
                        isExpanded: $isBalanceLookupExpanded
                    ) {
                        TrezorBalanceLookupContent()
                    }

                    TrezorExpandableSection(
                        title: "Device Info",
                        icon: "info.circle",
                        description: "View device details and features",
                        isExpanded: $isDeviceInfoExpanded
                    ) {
                        TrezorDeviceFeaturesContent()
                    }
                }

                // Disconnect button
                Button(action: {
                    Task {
                        await trezor.disconnect()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "eject")
                        Text("Disconnect")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black)
        .navigationTitle("Trezor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                TrezorStatusBadge(
                    isConnected: trezor.isConnected,
                    deviceName: trezor.deviceFeatures?.label
                )
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Device Info Card

private struct DeviceInfoCard: View {
    let device: TrezorDeviceInfo?
    let features: TrezorFeatures?

    var body: some View {
        VStack(spacing: 16) {
            // Icon
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 40))
                .foregroundColor(.white)
                .padding(20)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())

            // Device name
            VStack(spacing: 4) {
                Text(features?.label ?? "Trezor")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                if let model = features?.model {
                    Text("Model \(model)")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            // Firmware version
            if let major = features?.majorVersion,
               let minor = features?.minorVersion,
               let patch = features?.patchVersion
            {
                Text("Firmware: \(major).\(minor).\(patch)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorConnectedView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorConnectedView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
