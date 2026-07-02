import BitkitCore
import SwiftUI

/// View displayed when connected to a Trezor device.
/// Uses expandable sections instead of navigation to separate screens.
struct TrezorConnectedView: View {
    @Environment(TrezorManager.self) private var trezorManager
    @State private var isAddressExpanded = false
    @State private var isSignMessageExpanded = false
    @State private var isPublicKeyExpanded = false
    @State private var isBalanceLookupExpanded = false
    @State private var isTxHistoryExpanded = false
    @State private var isTxDetailExpanded = false
    @State private var isWatcherExpanded = false
    @State private var isDeviceInfoExpanded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Device card
                DeviceInfoCard(
                    name: trezorManager.connectedDeviceDisplayName ?? "Trezor",
                    features: trezorManager.deviceFeatures
                )

                // Wallet mode selector (standard vs hidden/passphrase wallet)
                WalletModeSelectorRow()

                // Expandable sections
                VStack(spacing: 12) {
                    TrezorExpandableSection(
                        title: "Get Address",
                        icon: "qrcode",
                        description: "Generate a receiving address",
                        accessibilityIdentifier: "TrezorSection-Address",
                        isExpanded: $isAddressExpanded
                    ) {
                        TrezorAddressContent()
                    }

                    TrezorExpandableSection(
                        title: "Sign Message",
                        icon: "signature",
                        description: "Sign a message with your Trezor",
                        accessibilityIdentifier: "TrezorSection-SignMessage",
                        isExpanded: $isSignMessageExpanded
                    ) {
                        TrezorSignMessageContent()
                    }

                    TrezorExpandableSection(
                        title: "Public Key",
                        icon: "key",
                        description: "Get xpub and public key",
                        accessibilityIdentifier: "TrezorSection-PublicKey",
                        isExpanded: $isPublicKeyExpanded
                    ) {
                        TrezorPublicKeyContent()
                    }

                    TrezorExpandableSection(
                        title: "Balance Lookup",
                        icon: "magnifyingglass",
                        description: "Check balance & UTXOs for any address or xpub",
                        accessibilityIdentifier: "TrezorSection-BalanceLookup",
                        isExpanded: $isBalanceLookupExpanded
                    ) {
                        TrezorBalanceLookupContent()
                    }

                    TrezorExpandableSection(
                        title: "Transaction History",
                        icon: "list.bullet.rectangle",
                        description: "Get transaction history for any xpub",
                        accessibilityIdentifier: "TrezorSection-TxHistory",
                        isExpanded: $isTxHistoryExpanded
                    ) {
                        TrezorTransactionHistoryContent()
                    }

                    TrezorExpandableSection(
                        title: "Transaction Detail",
                        icon: "doc.text.magnifyingglass",
                        description: "Get detailed info for a specific transaction",
                        accessibilityIdentifier: "TrezorSection-TxDetail",
                        isExpanded: $isTxDetailExpanded
                    ) {
                        TrezorTransactionDetailContent()
                    }

                    TrezorExpandableSection(
                        title: "Event Watcher",
                        icon: "dot.radiowaves.left.and.right",
                        description: "Watch an xpub for live on-chain activity",
                        accessibilityIdentifier: "TrezorSection-Watcher",
                        isExpanded: $isWatcherExpanded
                    ) {
                        TrezorWatcherContent()
                    }

                    TrezorExpandableSection(
                        title: "Device Info",
                        icon: "info.circle",
                        description: "View device details and features",
                        accessibilityIdentifier: "TrezorSection-DeviceInfo",
                        isExpanded: $isDeviceInfoExpanded
                    ) {
                        TrezorDeviceFeaturesContent()
                    }
                }

                // Disconnect button
                Button(action: {
                    Task {
                        await trezorManager.disconnect()
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
                .accessibilityIdentifier("TrezorDisconnectButton")
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
        .trezorAccessibilityAnchor("TrezorConnectedView")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                TrezorStatusBadge(
                    isConnected: trezorManager.isConnected,
                    deviceName: trezorManager.connectedDeviceDisplayName
                )
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Wallet Mode Selector

/// Lets the user switch between the standard wallet and a hidden (passphrase) wallet.
/// Switching resets the device session (handled by the ViewModel).
private struct WalletModeSelectorRow: View {
    @Environment(TrezorManager.self) private var trezorManager
    @Environment(TrezorViewModel.self) private var trezor

    private enum WalletModeTab: CaseIterable, CustomStringConvertible {
        case standard
        case passphrase

        var description: String {
            switch self {
            case .standard: "Standard"
            case .passphrase: "Passphrase"
            }
        }
    }

    /// Selecting a tab kicks off the wallet switch; the underline only moves
    /// once the ViewModel actually changes `walletMode` (e.g. after the
    /// passphrase flow completes).
    private var selectedTab: Binding<WalletModeTab> {
        Binding(
            get: { trezorManager.walletMode == .standard ? .standard : .passphrase },
            set: { newValue in
                switch newValue {
                case .standard:
                    Task { await trezorManager.selectStandardWallet() }
                case .passphrase:
                    trezorManager.requestPassphraseWallet()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText("Wallet")

            SegmentedControl(selectedTab: selectedTab, tabs: WalletModeTab.allCases)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(trezor.isOperating)
    }
}

// MARK: - Device Info Card

private struct DeviceInfoCard: View {
    let name: String
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
                Text(name)
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
        .trezorAccessibilityAnchor("TrezorDeviceInfoCard")
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorConnectedView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorConnectedView()
            }
            .environment(TrezorManager())
        }
    }
#endif
