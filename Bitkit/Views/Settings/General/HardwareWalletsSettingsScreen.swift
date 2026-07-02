import SwiftUI

/// Manages all paired hardware wallets, reachable from Settings ▸ General ▸ Payments. Lists each
/// paired device with a connection badge, name, balance and a per-row delete; an intro-style empty
/// state when none are paired; and an "Add Hardware Wallet" button that opens the existing intro
/// flow. Tapping a row opens the device's `HardwareWalletScreen`.
struct HardwareWalletsSettingsScreen: View {
    @Environment(HwWalletManager.self) private var hwWalletManager
    @Environment(TrezorManager.self) private var trezorManager
    @EnvironmentObject private var sheets: SheetViewModel

    @State private var pendingRemoval: HwWallet?

    private var wallets: [HwWallet] {
        hwWalletManager.wallets
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("settings__hardware_wallets__nav_title"))
                .padding(.horizontal, 16)

            if wallets.isEmpty {
                emptyState
            } else {
                deviceList
            }

            CustomButton(
                title: t("settings__hardware_wallets__add_button"),
                shouldExpand: true
            ) {
                sheets.showSheet(.hardwareIntro)
            }
            .accessibilityIdentifier("AddHardwareWallet")
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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
        VStack(spacing: 0) {
            HwDeviceIllustrations()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(t("hardware__intro_header"), accentColor: .blueAccent)
                BodyMText(t("hardware__intro_text"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

    private var deviceList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(wallets) { wallet in
                    HwWalletRow(
                        wallet: wallet,
                        onRename: {
                            sheets.showSheet(
                                .renameHardwareWallet,
                                data: RenameHardwareWalletConfig(deviceId: wallet.id, currentName: wallet.name)
                            )
                        },
                        onRemove: { pendingRemoval = wallet }
                    )
                    CustomDivider()
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .bottom) {
            HwDeviceIllustrations()
                .frame(height: 256)
                .padding(.bottom, 59.77)
                .allowsHitTesting(false)
        }
    }

    private func remove(_ wallet: HwWallet) async {
        pendingRemoval = nil
        hwWalletManager.removeDevice(id: wallet.id)
        for id in wallet.deviceIds {
            await trezorManager.forgetDevice(id: id)
        }
    }
}

/// A paired hardware wallet row: connection badge, name, balance and a trailing delete. Tapping the
/// name opens the rename sheet; the trash button removes the device.
private struct HwWalletRow: View {
    let wallet: HwWallet
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HwConnectionBadge(isConnected: wallet.isConnected)

            Button(action: onRename) {
                BodyMText(wallet.name, textColor: .textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HardwareWalletRowName_\(wallet.id)")

            MoneyText(
                sats: Int(clamping: wallet.balanceSats),
                size: .bodyMSB,
                symbol: true,
                color: .white64,
                symbolColor: .white64
            )

            Button(action: onRemove) {
                Image("trash")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("HardwareWalletRowDelete_\(wallet.id)")
        }
        .frame(height: 50)
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
