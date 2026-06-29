import SwiftUI

/// Manages all paired hardware wallets, reachable from Settings ▸ General ▸ Payments. Lists each
/// paired device with a connection badge, name, balance and a per-row delete; an empty state when
/// none are paired; and an "Add Hardware Wallet" button that opens the existing intro flow. Tapping
/// a row opens the device's `HardwareWalletScreen`. Ports bitkit-android's `HardwareWalletsSettingsScreen`.
struct HardwareWalletsSettingsScreen: View {
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(TrezorManager.self) private var trezorManager
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    @State private var pendingRemoval: HwWallet?

    private var wallets: [HwWallet] {
        hwWalletManager.wallets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__hardware_wallets__nav_title"))
                .padding(.horizontal, 16)

            ZStack(alignment: .bottom) {
                HwDeviceIllustrations()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, ScreenLayout.bottomPaddingWithSafeArea)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    if wallets.isEmpty {
                        emptyState
                            .frame(maxHeight: .infinity, alignment: .center)
                    } else {
                        deviceList
                    }

                    CustomButton(
                        title: t("settings__hardware_wallets__add_button"),
                        variant: .secondary,
                        shouldExpand: true
                    ) {
                        sheets.showSheet(.hardwareIntro)
                    }
                    .accessibilityIdentifier("AddHardwareWallet")
                    .padding(.bottom, 16)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationBarHidden(true)
        .accessibilityIdentifier("HardwareWalletsScreen")
        .alert(
            t("hardware__remove_dialog_title", variables: ["name": pendingRemoval?.name ?? ""]),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button(t("common__remove"), role: .destructive) {
                guard let wallet = pendingRemoval else { return }
                Task { await remove(wallet) }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("hardware__remove_dialog_text"))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisplayText(t("settings__hardware_wallets__nav_title"))
            BodyMText(t("settings__hardware_wallets__empty_text"), textColor: .white80)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deviceList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(wallets) { wallet in
                    HwWalletRow(
                        wallet: wallet,
                        onTap: { navigation.navigate(.hardwareWallet(deviceId: wallet.id)) },
                        onRemove: { pendingRemoval = wallet }
                    )
                    CustomDivider()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Stop watching and forget every entry for the device (it may be paired over multiple
    /// transports). Mirrors `HardwareWalletScreen.removeWallet()`: `removeDevice` stops the watchers
    /// and deletes the persisted activities, then `forgetDevice` clears credentials and drops the
    /// known-device entry, which re-pushes the snapshot and removes it from the list.
    private func remove(_ wallet: HwWallet) async {
        pendingRemoval = nil
        hwWalletManager.removeDevice(id: wallet.id)
        for id in wallet.deviceIds {
            await trezorManager.forgetDevice(id: id)
        }
    }
}

/// A paired hardware wallet row: connection badge, name, balance and a trailing delete. The badge,
/// name and balance navigate to the device's detail screen; the trash button removes it.
private struct HwWalletRow: View {
    let wallet: HwWallet
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    HwConnectionBadge(isConnected: wallet.isConnected)

                    BodyMText(wallet.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    MoneyText(
                        sats: Int(clamping: wallet.balanceSats),
                        size: .bodySSB,
                        symbol: true,
                        color: .white64,
                        symbolColor: .white64
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image("trash")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.white64)
                    .padding(.leading, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HardwareWalletRowDelete_\(wallet.id)")
        }
        .frame(height: 52)
        .accessibilityIdentifier("HardwareWalletRow_\(wallet.id)")
    }
}

/// Circular connection badge tinting the shared Bluetooth glyph green when connected, gray otherwise.
private struct HwConnectionBadge: View {
    let isConnected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isConnected ? Color.green16 : Color.white16)
                .frame(width: 32, height: 32)

            HwWalletConnectionIcon(isConnected: isConnected)
                .frame(width: 16, height: 16)
        }
    }
}

#Preview("With devices") {
    NavigationStack {
        HardwareWalletsSettingsScreen()
            .environment(HwWalletManager())
            .environment(TrezorManager())
            .environmentObject(SheetViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(SettingsViewModel.shared)
    }
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    NavigationStack {
        HardwareWalletsSettingsScreen()
            .environment(HwWalletManager())
            .environment(TrezorManager())
            .environmentObject(SheetViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(SettingsViewModel.shared)
    }
    .preferredColorScheme(.dark)
}
